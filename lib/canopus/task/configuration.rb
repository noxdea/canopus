# frozen_string_literal: true

require "kochab"
require_relative "../error"

module Canopus
  module Task
    class Configuration
      RELATIVE_PATH = File.join(".canopus", "tasks.jsonc")
      MAX_BYTES = 1_048_576
      MAX_TASKS = 128
      MAX_PROBLEM_MATCHERS = 128
      MAX_DEPTH = 20
      MAX_COLLECTION_SIZE = 1_024
      MAX_STRING_BYTES = 65_536
      MAX_EXPANDED_BYTES = 1_048_576
      MAX_ENVIRONMENT_BYTES = 1_048_576
      VARIABLE = /\$\{([^{}]+)\}/

      attr_reader :root, :tasks, :problem_matchers

      def initialize(root:, environment: ENV)
        @root = canonical_root(root)
        @environment = snapshot_environment(environment)
        @problem_matchers = {}.freeze
        @tasks = load_tasks
      end

      def problem_matcher(name) = @problem_matchers[name]

      def resolve(task, file: nil, line_number: nil, selected_text: nil)
        source = task.is_a?(String) ? @tasks.find { |item| item["label"] == task } :
          @tasks.find { |item| item.equal?(task) }
        raise Error, "unknown task" unless source

        variables = context(file, line_number, selected_text)
        budget = [MAX_EXPANDED_BYTES]
        labels = @tasks.map do |entry|
          expand_string(entry.fetch("label"), variables, budget).tap do |label|
            bounded_identifier(label, "expanded task label", 256)
          end
        end
        raise Error, "expanded task labels must be unique" unless labels.uniq.length == labels.length

        resolved = expand_value(source, variables, budget)
        bounded_identifier(resolved.fetch("label"), "expanded task label", 256)
        raise Error, "task executable must not be empty" if resolved.fetch("command").first.empty?
        resolved["cwd"] = project_path(resolved.fetch("cwd", @root), "cwd")
        raise Error, "task cwd must be a directory" unless File.directory?(resolved["cwd"])
        freeze_value(resolved)
      end

      private

      def canonical_root(root)
        path = File.realpath(root)
        raise Error, "task workspace root must be a directory" unless File.directory?(path)

        path.freeze
      rescue SystemCallError, TypeError => error
        raise Error, "invalid task workspace root: #{error.message}"
      end

      def load_tasks
        path = File.join(@root, RELATIVE_PATH)
        unless File.exist?(path)
          raise Error, "task configuration path is a broken symlink" if File.symlink?(path)
          return [].freeze
        end
        real_path = File.realpath(path)
        raise Error, "task configuration is outside the workspace" unless inside_root?(real_path)
        raise Error, "task configuration must be a regular file" unless File.file?(real_path)
        raise Error, "task configuration exceeds 1 MiB" if File.size(real_path) > MAX_BYTES

        source = File.binread(real_path, MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
        raise Error, "task configuration must be valid UTF-8" unless source.valid_encoding?
        raise Error, "task configuration exceeds 1 MiB" if source.bytesize > MAX_BYTES
        document = Kochab.parse(source)
        raise Error, "invalid task configuration: #{RELATIVE_PATH}" unless document.valid?
        root = document.value
        raise Error, "task configuration must be an object" unless root.is_a?(Hash) && root.keys.all? { |key| key.is_a?(String) }
        @problem_matchers = validate_problem_matchers(root.fetch("problem_matchers", {}))
        entries = root.fetch("tasks", [])
        unless entries.is_a?(Array) && entries.length <= MAX_TASKS
          raise Error, "tasks must be an array of at most #{MAX_TASKS} items"
        end
        entries = entries.map { |entry| validate_task(entry) }
        labels = entries.map { |entry| entry["label"] }
        raise Error, "task labels must be unique" unless labels.uniq.length == labels.length

        entries.freeze
      rescue SystemCallError => error
        raise Error, "cannot read task configuration: #{error.message}"
      end

      def validate_problem_matchers(value)
        unless value.is_a?(Hash) && value.length <= MAX_PROBLEM_MATCHERS && value.keys.all? { |name| name.is_a?(String) }
          raise Error, "problem_matchers must be an object of at most #{MAX_PROBLEM_MATCHERS} items"
        end
        value.to_h do |name, definition|
          bounded_identifier(name, "problem matcher name", 256)
          [name.dup.freeze, validate_problem_matcher(definition)]
        end.freeze
      end

      def validate_problem_matcher(definition)
        raise Error, "each problem matcher must be an object" unless definition.is_a?(Hash)
        validate_json(definition)
        owner = definition.fetch("owner", "task")
        bounded_identifier(owner, "problem matcher owner", 128)
        patterns = definition["pattern"]
        patterns = [patterns] if patterns.is_a?(Hash)
        unless patterns.is_a?(Array) && patterns.length.between?(1, 8)
          raise Error, "problem matcher pattern must contain 1 to 8 patterns"
        end
        patterns = patterns.map { |pattern| validate_problem_pattern(pattern) }
        unless %w[file line message].all? { |key| patterns.any? { |pattern| pattern[key] } }
          raise Error, "problem matcher patterns require file, line, and message captures"
        end
        location = validate_file_location(definition.fetch("file_location", ["relative", "${workspaceFolder}"]))
        background = validate_problem_background(definition["background"])
        result = definition.merge("owner" => owner.dup.freeze,
          "file_location" => location, "pattern" => definition["pattern"].is_a?(Hash) ? patterns.first : patterns)
        result["background"] = background if background
        freeze_value(result)
      rescue KeyError
        raise Error, "problem matcher pattern is required"
      end

      def validate_problem_pattern(pattern)
        raise Error, "problem matcher pattern must be an object" unless pattern.is_a?(Hash)
        source = pattern["regexp"]
        valid_string!(source, "problem matcher regexp", 16_384)
        Regexp.new(source, timeout: 0.05)
        %w[file line column end_line end_column severity message].each do |name|
          index = pattern[name]
          unless index.nil? || index.is_a?(Integer) && index.between?(1, 99)
            raise Error, "problem matcher #{name} must be a capture index from 1 to 99"
          end
        end
        freeze_value(pattern.dup)
      rescue RegexpError
        raise Error, "invalid problem matcher regexp"
      end

      def validate_file_location(value)
        if value == "absolute"
          return ["absolute".freeze, @root].freeze
        end
        unless value.is_a?(Array) && value.length == 2 && value.first == "relative" && value.last.is_a?(String)
          raise Error, "problem matcher file_location must be absolute or [relative, base]"
        end
        base = expand_string(value.last, {}, [MAX_EXPANDED_BYTES])
        base = project_path(base, "problem matcher file location")
        raise Error, "problem matcher file location must be a directory" unless File.directory?(base)
        ["relative".freeze, base.freeze].freeze
      end

      def validate_problem_background(value)
        return unless value
        raise Error, "problem matcher background must be an object" unless value.is_a?(Hash)
        begins = value["begins_pattern"]
        ends = value["ends_pattern"]
        valid_string!(begins, "problem matcher begins_pattern", 16_384)
        valid_string!(ends, "problem matcher ends_pattern", 16_384)
        unless !value.key?("active_on_start") || [true, false].include?(value["active_on_start"])
          raise Error, "problem matcher active_on_start must be boolean"
        end
        Regexp.new(begins, timeout: 0.05)
        Regexp.new(ends, timeout: 0.05)
        freeze_value(value.merge("active_on_start" => value.fetch("active_on_start", false)))
      rescue RegexpError
        raise Error, "invalid problem matcher background regexp"
      end

      def validate_task(entry)
        raise Error, "each task must be an object" unless entry.is_a?(Hash)
        validate_json(entry)
        bounded_identifier(entry["label"], "task label", 256)
        command = entry["command"]
        unless command.is_a?(Array) && command.length.between?(1, 256) && command.all? { |part| part.is_a?(String) }
          raise Error, "task command must be an array of 1 to 256 strings"
        end
        raise Error, "task executable must not be empty" if command.first.empty?
        raise Error, "task cwd must be a string" if entry.key?("cwd") && !entry["cwd"].is_a?(String)
        if entry.key?("problem_matcher") && !entry["problem_matcher"].is_a?(String)
          raise Error, "task problem_matcher must be a string"
        end
        presentation = entry.fetch("presentation", {})
        raise Error, "task presentation must be an object" unless presentation.is_a?(Hash)
        panel = presentation.fetch("panel", "output")
        reveal = presentation.fetch("reveal", "always")
        raise Error, "task presentation panel must be output" unless panel == "output"
        raise Error, "invalid task presentation reveal" unless %w[always silent never].include?(reveal)

        freeze_value(entry.merge("presentation" => presentation.merge("panel" => panel, "reveal" => reveal)))
      end

      def validate_json(value, depth = 0)
        raise Error, "task configuration is nested too deeply" if depth > MAX_DEPTH
        case value
        when Hash
          raise Error, "task object has too many properties" if value.length > MAX_COLLECTION_SIZE
          value.each do |key, child|
            bounded_identifier(key, "task option name", 256)
            validate_json(child, depth + 1)
          end
        when Array
          raise Error, "task array has too many items" if value.length > MAX_COLLECTION_SIZE
          value.each { |child| validate_json(child, depth + 1) }
        when String
          valid_string!(value, "task string", MAX_STRING_BYTES)
        when Integer, TrueClass, FalseClass, NilClass
          nil
        when Float
          raise Error, "task numbers must be finite" unless value.finite?
        else
          raise Error, "unsupported task value"
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
        when Hash then value.to_h { |key, child| [key.dup, expand_value(child, variables, budget)] }
        when Array then value.map { |child| expand_value(child, variables, budget) }
        when String then expand_string(value, variables, budget)
        else value
        end
      end

      def expand_string(value, variables, budget)
        expanded = +""
        cursor = 0
        remaining = MAX_EXPANDED_BYTES
        while (match = VARIABLE.match(value, cursor))
          marker = value.index("${", cursor)
          raise Error, "malformed task variable" unless marker == match.begin(0)
          remaining = append_expanded!(expanded, value[cursor...marker], budget, remaining)
          name = match[1]
          replacement = if name == "workspaceFolder"
            @root
          elsif variables.key?(name)
            variable(name, variables[name])
          elsif name.start_with?("env:")
            environment_variable(name.delete_prefix("env:"))
          else
            raise Error, "unknown task variable: #{name}"
          end
          remaining = append_expanded!(expanded, replacement, budget, remaining)
          cursor = match.end(0)
        end
        raise Error, "malformed task variable" if value.index("${", cursor)
        append_expanded!(expanded, value[cursor..] || "", budget, remaining)
        expanded
      end

      def append_expanded!(output, value, budget, remaining)
        bytes = value.bytesize
        raise Error, "expanded task data exceeds 1 MiB" if bytes > remaining || bytes > budget[0]

        output << value
        budget[0] -= bytes
        remaining - bytes
      end

      def variable(name, value)
        raise Error, "task variable #{name} is unavailable" if value.nil?
        if name == "lineNumber"
          unless value.is_a?(Integer) && value.positive? && value <= 2_147_483_647
            raise Error, "lineNumber must be a positive integer"
          end
          return value.to_s
        end
        valid_string!(value, name, MAX_EXPANDED_BYTES)
        value
      end

      def environment_variable(name)
        raise Error, "invalid environment variable name" unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise Error, "environment variable #{name} is unavailable" unless @environment.key?(name)
        valid_string!(@environment[name], "environment variable #{name}", MAX_EXPANDED_BYTES)
        @environment[name]
      end

      def project_path(value, label)
        valid_string!(value, label, MAX_EXPANDED_BYTES)
        raise Error, "task #{label} must not be empty" if value.empty?
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
        raise Error, "task #{label} is outside the workspace" unless inside_root?(path)

        path
      rescue SystemCallError => error
        raise Error, "invalid task #{label}: #{error.message}"
      end

      def inside_root?(path)
        path == @root || path.start_with?(@root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}")
      end

      def snapshot_environment(environment)
        raise Error, "task environment must provide string pairs" unless environment.respond_to?(:each_pair)
        pairs, total = [], 0
        environment.each_pair do |key, value|
          raise Error, "task environment has too many entries" if pairs.length >= 4_096
          valid = key.is_a?(String) && value.is_a?(String) && key.valid_encoding? && value.valid_encoding? &&
            (key.encoding == Encoding::UTF_8 || key.ascii_only?) &&
            (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
            key.bytesize.between?(1, 256) && value.bytesize <= MAX_EXPANDED_BYTES &&
            !key.include?("\0") && !value.include?("\0")
          raise Error, "invalid task environment entry" unless valid
          total += key.bytesize + value.bytesize
          raise Error, "task environment exceeds 1 MiB" if total > MAX_ENVIRONMENT_BYTES
          pairs << [key, value]
        end
        pairs.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze
      end

      def freeze_value(value)
        value.each { |key, child| key.freeze; freeze_value(child) } if value.is_a?(Hash)
        value.each { |child| freeze_value(child) } if value.is_a?(Array)
        value.freeze
      end
    end
  end
end
