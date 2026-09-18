# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module Canopus
  module Plugins
    class Registry
      API_VERSION = "1"
      NAME_PATTERN = /\Acanopus-plugin-[a-z0-9][a-z0-9-]*\z/
      PERMISSIONS = Plugins::PERMISSIONS

      def initialize(workspace, state_path: nil)
        @workspace, @loaded = workspace, []
        @state_path = state_path || File.join(ENV["XDG_STATE_HOME"] || File.expand_path("~/.local/state"), "canopus", "plugins.json")
        @disabled = load_state
      end

      def search(query, limit: 20)
        require "rubygems/spec_fetcher"
        query = String(query)
        raise ArgumentError, "plugin search query must not be empty" if query.strip.empty?
        raise ArgumentError, "invalid plugin search limit" unless limit.is_a?(Integer) && limit.between?(1, 100)

        dependency = Gem::Dependency.new(query.start_with?("canopus-plugin-") ? query : "canopus-plugin-#{query}", Gem::Requirement.default)
        Gem::SpecFetcher.fetcher.search_for_dependency(dependency).first.filter_map do |entry, _source|
          spec = entry.is_a?(Array) ? entry.first : entry
          spec = spec.spec if spec.respond_to?(:spec)
          name = spec.respond_to?(:name) ? spec.name : nil
          next unless plugin_name?(name)
          {name: name, version: spec.respond_to?(:version) ? spec.version.to_s : "", summary: spec.respond_to?(:summary) ? spec.summary.to_s : "",
           api_version: spec.respond_to?(:metadata) ? spec.metadata["canopus_plugin_api_version"] : nil}
        end.uniq { |plugin| plugin[:name] }.first(limit)
      end

      def install(name, version: nil)
        require "rubygems/dependency_installer"
        name = validate_name(name)
        specifications = Gem::DependencyInstaller.new.install(name, version || Gem::Requirement.default)
        specification = specifications.reverse.find { |candidate| candidate.name == name }
        validate_specification!(specification)
        specification
      rescue Gem::Exception => error
        raise Canopus::Error, "plugin install failed: #{error.message}"
      end

      def update(name)
        install(name)
      end

      def disable(name)
        name = validate_name(name)
        @disabled[name] = true
        save_state
        true
      end

      def enable(name)
        name = validate_name(name)
        @disabled.delete(name)
        save_state
        true
      end

      def disabled?(name) = @disabled.key?(validate_name(name))

      def load_gem(name, trusted: false, permissions: [], isolated: true, timeout: 2)
        name = validate_name(name)
        raise Canopus::Error, "plugin is disabled: #{name}" if disabled?(name)
        specification = validate_specification!(Gem::Specification.find_all_by_name(name).max_by(&:version))
        entrypoint = specification.metadata["canopus_plugin_entrypoint"] || "lib/#{name}.rb"
        path = File.realpath(File.expand_path(entrypoint, specification.full_gem_path))
        prefix = File.realpath(specification.full_gem_path) + File::SEPARATOR
        raise Canopus::Error, "plugin entrypoint escapes gem directory" unless path.start_with?(prefix)

        load(path, trusted: trusted, permissions: permissions, isolated: isolated, timeout: timeout)
      rescue Errno::ENOENT
        raise Canopus::Error, "plugin entrypoint not found: #{name}"
      end

      def load(path, trusted: false, permissions: [], isolated: true, timeout: 2)
        raise PermissionDenied, "plugins execute Ruby code; explicitly mark this plugin trusted" unless trusted
        permissions = permissions.map { |permission| permission.to_s == "process" ? "exec" : permission.to_s }.uniq
        raise PermissionDenied, "unknown plugin permission" unless (permissions - PERMISSIONS).empty?
        source = File.read(path, 256 * 1024 + 1, encoding: "UTF-8")
        raise Error, "plugin source exceeds 256KB" if source.bytesize > 256 * 1024
        plugin = if isolated
          IsolatedRuntime.new(@workspace, source, path, permissions, timeout: timeout)
        else
          LocalRuntime.new(@workspace, source, path, permissions)
        end
        @loaded << plugin
        plugin
      end

      def close = @loaded.each(&:close)

      private

      def plugin_name?(name) = NAME_PATTERN.match?(name.to_s)

      def validate_name(name)
        name = String(name)
        raise ArgumentError, "plugin gem name must match canopus-plugin-*" unless plugin_name?(name)
        name
      end

      def validate_specification!(specification)
        raise Canopus::Error, "plugin gem was not found" unless specification
        unless plugin_name?(specification.name)
          raise Canopus::Error, "plugin gem name must match canopus-plugin-*"
        end
        version = specification.metadata["canopus_plugin_api_version"]
        raise Canopus::Error, "unsupported plugin API version" unless version == API_VERSION
        specification
      end

      def load_state
        return {} unless File.file?(@state_path)
        value = JSON.parse(File.read(@state_path))
        value.is_a?(Hash) ? value.select { |name, disabled| plugin_name?(name) && disabled == true } : {}
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
        {}
      end

      def save_state
        FileUtils.mkdir_p(File.dirname(@state_path))
        Tempfile.create([".plugins-", ".json"], File.dirname(@state_path)) do |file|
          file.write(JSON.generate(@disabled))
          file.flush
          file.fsync
          file.close
          File.rename(file.path, @state_path)
        end
      rescue SystemCallError => error
        raise Canopus::Error, "cannot save plugin state: #{error.message}"
      end
    end
  end
end
