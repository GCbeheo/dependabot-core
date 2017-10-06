# frozen_string_literal: true

require "parser/current"

require "dependabot/update_checkers/ruby/bundler"
require "dependabot/dependency_file"
require "dependabot/file_updaters/ruby/bundler/git_pin_replacer"
require "dependabot/file_updaters/ruby/bundler/git_source_remover"

module Dependabot
  module UpdateCheckers
    module Ruby
      class Bundler
        # This class takes a set of dependency files and sanitizes them for use
        # in UpdateCheckers::Ruby::Bundler. In particular, it:
        # - Removes any version requirement on the dependency being updated
        #   (in the Gemfile)
        # - Sanitizes any provided gemspecs to remove file imports etc. (since
        #   Dependabot doesn't pull down the entire repo). This process is
        #   imperfect - an alternative would be to clone the repo
        class FilePreparer
          def initialize(dependency_files:, dependency:,
                         remove_git_source: false,
                         replacement_git_pin: nil)
            @dependency_files = dependency_files
            @dependency = dependency
            @remove_git_source = remove_git_source
            @replacement_git_pin = replacement_git_pin
          end

          # rubocop:disable Metrics/AbcSize
          # rubocop:disable Metrics/MethodLength
          def prepared_dependency_files
            files = []

            if gemfile
              files << DependencyFile.new(
                name: gemfile.name,
                content: gemfile_content_for_update_check(gemfile),
                directory: gemfile.directory
              )
            end

            if gemspec
              files << DependencyFile.new(
                name: gemspec.name,
                content: gemspec_content_for_update_check,
                directory: gemspec.directory
              )
            end

            path_gemspecs.each do |file|
              files << DependencyFile.new(
                name: file.name,
                content: sanitize_gemspec_content(file.content),
                directory: file.directory
              )
            end

            evaled_gemfiles.each do |file|
              files << DependencyFile.new(
                name: file.name,
                content: gemfile_content_for_update_check(file),
                directory: file.directory
              )
            end

            # No editing required for lockfile or Ruby version file
            files += [lockfile, ruby_version_file].compact
          end
          # rubocop:enable Metrics/AbcSize
          # rubocop:enable Metrics/MethodLength

          private

          attr_reader :dependency_files, :dependency, :replacement_git_pin

          def remove_git_source?
            @remove_git_source
          end

          def replace_git_pin?
            !replacement_git_pin.nil?
          end

          def gemfile
            dependency_files.find { |f| f.name == "Gemfile" }
          end

          def evaled_gemfiles
            dependency_files.
              reject { |f| f.name.end_with?(".gemspec") }.
              reject { |f| f.name.end_with?(".lock") }.
              reject { |f| f.name.end_with?(".ruby-version") }.
              reject { |f| f.name == "Gemfile" }
          end

          def lockfile
            dependency_files.find { |f| f.name == "Gemfile.lock" }
          end

          def gemspec
            dependency_files.find { |f| f.name.match?(%r{^[^/]*\.gemspec$}) }
          end

          def ruby_version_file
            dependency_files.find { |f| f.name == ".ruby-version" }
          end

          def path_gemspecs
            all = dependency_files.select { |f| f.name.end_with?(".gemspec") }
            all - [gemspec]
          end

          def gemfile_content_for_update_check(file)
            content = replace_gemfile_version_requirement(file.content)
            content = remove_git_source(content) if remove_git_source?
            content = replace_git_pin(content) if replace_git_pin?
            content
          end

          def gemspec_content_for_update_check
            content = replace_gemspec_version_requirement(gemspec.content)
            sanitize_gemspec_content(content)
          end

          def replace_gemfile_version_requirement(content)
            buffer = Parser::Source::Buffer.new("(gemfile_content)")
            buffer.source = content
            ast = Parser::CurrentRuby.new.parse(buffer)

            updated_version =
              if dependency.version&.match?(/^[0-9a-f]{40}$/) then 0
              elsif dependency.version then dependency.version
              else 0
              end

            ReplaceGemfileRequirement.new(
              dependency_name: dependency.name,
              updated_version: updated_version
            ).rewrite(buffer, ast)
          end

          def replace_gemspec_version_requirement(content)
            buffer = Parser::Source::Buffer.new("(gemspec_content)")
            buffer.source = content
            ast = Parser::CurrentRuby.new.parse(buffer)

            RemoveGemspecRequirement.new(
              dependency_name: dependency.name
            ).rewrite(buffer, ast)
          end

          def sanitize_gemspec_content(gemspec_content)
            # No need to set the version correctly - this is just an update
            # check so we're not going to persist any changes to the lockfile.
            gemspec_content.
              gsub(/^\s*require.*$/, "").
              gsub(/=.*VERSION.*$/, "= '0.0.1'")
          end

          def remove_git_source(content)
            buffer = ::Parser::Source::Buffer.new("(gemfile_content)")
            buffer.source = content
            ast = Parser::CurrentRuby.new.parse(buffer)

            FileUpdaters::Ruby::Bundler::GitSourceRemover.new(
              dependency: dependency
            ).rewrite(buffer, ast)
          end

          def replace_git_pin(content)
            buffer = ::Parser::Source::Buffer.new("(gemfile_content)")
            buffer.source = content
            ast = Parser::CurrentRuby.new.parse(buffer)

            FileUpdaters::Ruby::Bundler::GitPinReplacer.new(
              dependency: dependency,
              new_pin: replacement_git_pin
            ).rewrite(buffer, ast)
          end

          class ReplaceGemfileRequirement < Parser::Rewriter
            SKIPPED_TYPES = %i(send lvar dstr).freeze

            def initialize(dependency_name:, updated_version:)
              @dependency_name = dependency_name
              @updated_version = updated_version
            end

            def on_send(node)
              return unless declares_targeted_gem?(node)

              req_nodes = node.children[3..-1]
              req_nodes = req_nodes.reject { |child| child.type == :hash }

              return if req_nodes.none?
              return if req_nodes.any? { |n| SKIPPED_TYPES.include?(n.type) }

              range_to_replace =
                req_nodes.first.loc.expression.join(
                  req_nodes.last.loc.expression
                )
              replace(range_to_replace, "'>= #{updated_version}'")
            end

            private

            attr_reader :dependency_name, :updated_version

            def declares_targeted_gem?(node)
              return false unless node.children[1] == :gem
              node.children[2].children.first == dependency_name
            end
          end

          class RemoveGemspecRequirement < Parser::Rewriter
            SKIPPED_TYPES = %i(send lvar dstr).freeze
            DECLARATION_METHODS = %i(add_dependency add_runtime_dependency
                                     add_development_dependency).freeze

            def initialize(dependency_name:)
              @dependency_name = dependency_name
            end

            def on_send(node)
              return unless declares_targeted_gem?(node)

              req_nodes = node.children[3..-1]
              return if req_nodes.none?
              return if req_nodes.any? { |n| SKIPPED_TYPES.include?(n.type) }

              range_to_remove =
                node.children[2].loc.end.end.join(
                  req_nodes.last.loc.expression
                )
              remove(range_to_remove)
            end

            private

            attr_reader :dependency_name

            def declares_targeted_gem?(node)
              return false unless DECLARATION_METHODS.include?(node.children[1])
              node.children[2].children.first == dependency_name
            end
          end
        end
      end
    end
  end
end
