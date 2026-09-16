# frozen_string_literal: true

require "kochab"
require_relative "../error"
require_relative "../settings"

module Canopus
  module Debug
    class Configuration
      RELATIVE_PATH = File.join(".canopus", "launch.jsonc")
      MAX_BYTES = 1_048_576
      MAX_CONFIGURATIONS = 128
      MAX_DEPTH = 20
      MAX_COLLECTION_SIZE = 1_024
      MAX_STRING_BYTES = 65_536
      MAX_EXPANDED_STRING_BYTES = 1_048_576
      MAX_TOTAL_EXPANDED_BYTES = 1_048_576
      MAX_ENVIRONMENT_ENTRY_BYTES = 1_048_576
      MAX_ENVIRONMENT_BYTES = 1_048_576
      VARIABLE = /\$\{([^{}]+)\}/

      attr_reader :root, :configurations

      def initialize(root:, settings: Settings.new, environment: ENV)
        @root = canonical_root(root)
        @settings = settings
        @environment = snapshot_environment(environment)
        @configurations = load_configurations
      end

      def resolve(configuration, file: nil, line_number: nil, selected_text: nil)
        source = configuration.is_a?(String) ? @configurations.find { |item| item["name"] == configuration } :
          @configurations.find { |item| item.equal?(configuration) }
        raise Error, "unknown debug configuration" unless source
        resolved = expand_value(source, context(file, line_number, selected_text), [MAX_TOTAL_EXPANDED_BYTES])
        %w[program cwd].each do |key|
          resolved[key] = project_path(resolved[key], key) if resolved.key?(key)
        end
        freeze_value(resolved)
      end

      def adapter(type, file: nil, line_number: nil, selected_text: nil)
        raise Error, "debug adapter type must be a string" unless type.is_a?(String)
        options = @settings["debug_adapters"]
        options = options[type] if options.is_a?(Hash)
        raise Error, "no debug adapter configured for #{type}" unless options
        freeze_value(expand_value(options, context(file, line_number, selected_text), [MAX_TOTAL_EXPANDED_BYTES]))
      end

      private

      def canonical_root(root)
        path = File.realpath(root)
        raise Error, "debug workspace root must be a directory" unless File.directory?(path)
        path.freeze
      rescue SystemCallError, TypeError => error
        raise Error, "invalid debug workspace root: #{error.message}"
      end

      def load_configurations
        path = File.join(@root, RELATIVE_PATH)
        unless File.exist?(path)
          raise Error, "debug configuration path is a broken symlink" if File.symlink?(path)
          return fallback_configurations
        end
        real_path = File.realpath(path)
        raise Error, "debug configuration is outside the workspace" unless inside_root?(real_path)
        raise Error, "debug configuration must be a regular file" unless File.file?(real_path)
        raise Error, "debug configuration exceeds 1 MiB" if File.size(real_path) > MAX_BYTES
        source = File.binread(real_path, MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
        raise Error, "debug configuration must be valid UTF-8" unless source.valid_encoding?
        raise Error, "debug configuration exceeds 1 MiB" if source.bytesize > MAX_BYTES
        document = Kochab.parse(source)
        raise Error, "invalid debug configuration: #{RELATIVE_PATH}" unless document.valid?
        root = document.value
        raise Error, "debug configuration must be an object" unless root.is_a?(Hash) && root.keys.all? { |key| key.is_a?(String) }
        entries = root.fetch("configurations", [])
        unless entries.is_a?(Array) && entries.length <= MAX_CONFIGURATIONS
          raise Error, "configurations must be an array of at most #{MAX_CONFIGURATIONS} items"
        end
        entries = entries.map { |entry| validate_configuration(entry) }
        names = entries.map { |entry| entry["name"] }
        raise Error, "debug configuration names must be unique" unless names.uniq.length == names.length
        entries.empty? ? fallback_configurations : entries.freeze
      rescue SystemCallError => error
        raise Error, "cannot read debug configuration: #{error.message}"
      end

      def validate_configuration(entry)
        raise Error, "each debug configuration must be an object" unless entry.is_a?(Hash)
        validate_json(entry)
        bounded_identifier(entry["name"], "debug configuration name", 256)
        type = bounded_identifier(entry["type"], "debug configuration type", 128)
        raise Error, "invalid debug configuration type" unless type.match?(/\A[A-Za-z0-9_.-]+\z/)
        raise Error, "debug request must be launch or attach" unless %w[launch attach].include?(entry["request"])
        %w[program cwd].each do |key|
          raise Error, "debug #{key} must be a string" if entry.key?(key) && !entry[key].is_a?(String)
        end
        if entry.key?("args") && !(entry["args"].is_a?(Array) && entry["args"].length <= 256 && entry["args"].all? { |arg| arg.is_a?(String) })
          raise Error, "debug args must be an array of at most 256 strings"
        end
        if entry.key?("env") && !(entry["env"].is_a?(Hash) && entry["env"].length <= 256 &&
          entry["env"].all? { |key, value| key.is_a?(String) && (value.nil? || value.is_a?(String)) })
          raise Error, "debug env must be an object of at most 256 string values"
        end
        freeze_value(entry)
      end

      def validate_json(value, depth = 0)
        raise Error, "debug configuration is nested too deeply" if depth > MAX_DEPTH
        case value
        when Hash
          raise Error, "debug object has too many properties" if value.length > MAX_COLLECTION_SIZE
          value.each do |key, child|
            bounded_identifier(key, "debug option name", 256)
            validate_json(child, depth + 1)
          end
        when Array
          raise Error, "debug array has too many items" if value.length > MAX_COLLECTION_SIZE
          value.each { |child| validate_json(child, depth + 1) }
        when String
          valid_string!(value, "debug string", MAX_STRING_BYTES)
        when Integer, TrueClass, FalseClass, NilClass
          nil
        when Float
          raise Error, "debug numbers must be finite" unless value.finite?
        else
          raise Error, "unsupported debug value"
        end
      end

      def bounded_identifier(value, label, maximum)
        valid_string!(value, label, maximum)
        unless value == value.strip && !value.empty? && !value.match?(/[\x00-\x1f\x7f]/)
          raise Error, "invalid #{label}"
        end
        value
      end

      def valid_string!(value, label, maximum)
        unless value.is_a?(String) && value.valid_encoding? &&
          (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
          value.bytesize <= maximum && !value.include?("\0")
          raise Error, "invalid #{label}"
        end
      end

      def context(file, line_number, selected_text)
        {"file" => file && project_path(file, "file"), "lineNumber" => line_number,
         "selectedText" => selected_text}
      end

      def expand_value(value, variables, budget)
        case value
        when Hash
          value.to_h { |key, child| [key.dup, expand_value(child, variables, budget)] }
        when Array
          value.map { |child| expand_value(child, variables, budget) }
        when String
          expand_string(value, variables, budget)
        else
          value
        end
      end

      def expand_string(value, variables, budget)
        expanded = +""
        cursor = 0
        remaining = MAX_EXPANDED_STRING_BYTES
        while (match = VARIABLE.match(value, cursor))
          marker = value.index("${", cursor)
          raise Error, "malformed debug variable" unless marker == match.begin(0)
          remaining = append_expanded!(expanded, value[cursor...marker], budget, remaining)
          name = match[1]
          replacement = if name == "workspaceFolder"
            @root
          elsif variables.key?(name)
            variable(name, variables[name])
          elsif name.start_with?("env:")
            environment_variable(name.delete_prefix("env:"))
          else
            raise Error, "unknown debug variable: #{name}"
          end
          remaining = append_expanded!(expanded, replacement, budget, remaining)
          cursor = match.end(0)
        end
        raise Error, "malformed debug variable" if value.index("${", cursor)
        append_expanded!(expanded, value[cursor..] || "", budget, remaining)
        expanded
      end

      def append_expanded!(output, value, budget, remaining)
        bytes = value.bytesize
        if bytes > remaining || bytes > budget[0]
          raise Error, "expanded debug data exceeds 1 MiB"
        end
        output << value
        budget[0] -= bytes
        remaining - bytes
      end

      def variable(name, value)
        raise Error, "debug variable #{name} is unavailable" if value.nil?
        if name == "lineNumber"
          raise Error, "lineNumber must be a positive integer" unless value.is_a?(Integer) && value.positive? && value <= 2_147_483_647
          return value.to_s
        end
        valid_string!(value, name, MAX_EXPANDED_STRING_BYTES)
        value
      end

      def environment_variable(name)
        raise Error, "invalid environment variable name" unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise Error, "environment variable #{name} is unavailable" unless @environment.key?(name)
        valid_string!(@environment[name], "environment variable #{name}", MAX_EXPANDED_STRING_BYTES)
        @environment[name]
      end

      def project_path(value, label)
        valid_string!(value, label, MAX_EXPANDED_STRING_BYTES)
        raise Error, "debug #{label} must not be empty" if value.empty?
        path = File.expand_path(value, @root)
        if File.exist?(path)
          path = File.realpath(path)
        else
          ancestor, suffix = path, []
          until File.exist?(ancestor) || File.dirname(ancestor) == ancestor
            suffix.unshift(File.basename(ancestor))
            ancestor = File.dirname(ancestor)
          end
          path = File.join(File.realpath(ancestor), *suffix) if File.exist?(ancestor)
        end
        raise Error, "debug #{label} is outside the workspace" unless inside_root?(path)
        cursor = path
        until cursor == @root
          if File.symlink?(cursor)
            raise Error, "debug #{label} is outside the workspace" unless inside_root?(File.realpath(cursor))
          end
          cursor = File.dirname(cursor)
        end
        raise Error, "debug cwd must be a directory" if label == "cwd" && File.exist?(path) && !File.directory?(path)
        raise Error, "debug program must not be a directory" if label == "program" && File.directory?(path)
        path
      rescue SystemCallError => error
        raise Error, "invalid debug #{label}: #{error.message}"
      end

      def inside_root?(path)
        path == @root || path.start_with?(@root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}")
      end

      def snapshot_environment(environment)
        raise Error, "debug environment must provide string pairs" unless environment.respond_to?(:each_pair)
        pairs, total = [], 0
        environment.each_pair do |key, value|
          raise Error, "debug environment has too many entries" if pairs.length >= 4_096
          valid = key.is_a?(String) && value.is_a?(String) && key.valid_encoding? && value.valid_encoding? &&
            (key.encoding == Encoding::UTF_8 || key.ascii_only?) &&
            (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
            key.bytesize.between?(1, 256) && value.bytesize <= MAX_ENVIRONMENT_ENTRY_BYTES &&
            !key.include?("\0") && !value.include?("\0")
          raise Error, "invalid debug environment entry" unless valid
          total += key.bytesize + value.bytesize
          raise Error, "debug environment exceeds 1 MiB" if total > MAX_ENVIRONMENT_BYTES
          pairs << [key, value]
        end
        pairs.to_h do |key, value|
          [key.dup.freeze, value.dup.freeze]
        end.freeze
      end

      def fallback_configurations
        rakefile = %w[Rakefile rakefile].find do |name|
          path = File.join(@root, name)
          File.file?(path) && inside_root?(File.realpath(path))
        end
        return [].freeze unless rakefile
        [freeze_value({"name" => "Run tests", "type" => "ruby", "request" => "launch",
          "program" => "${workspaceFolder}/bin/rake", "args" => ["test"], "cwd" => "${workspaceFolder}"})].freeze
      rescue SystemCallError
        [].freeze
      end

      def freeze_value(value)
        value.each { |key, child| key.freeze; freeze_value(child) } if value.is_a?(Hash)
        value.each { |child| freeze_value(child) } if value.is_a?(Array)
        value.freeze
      end
    end
  end
end
