# frozen_string_literal: true

require "rbconfig"
require "digest/sha2"

module Canopus
  module TestRunner
    class Execution
      MAX_OUTPUT_BYTES = 256 << 10
      MAX_PARSE_LINES = 10_000
      MAX_FILTER_BYTES = 8_192
      ANSI = /\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a]*(?:\a|\e\\))/n

      attr_reader :test, :tests, :output, :generation

      def self.task(test, root:, tests: [test])
        raise ArgumentError, "discovered test required" unless test.is_a?(Test)
        unless tests.is_a?(Array) && !tests.empty? && tests.length <= Discovery::MAX_TESTS &&
            tests.all? { |candidate| candidate.is_a?(Test) && candidate.framework == test.framework &&
              candidate.path == test.path && candidate.line == test.line }
          raise ArgumentError, "related discovered tests required"
        end

        root = File.realpath(root)
        relative = TestRunner.normalize_path(test.path)
        raise Error, "Test target is invalid" unless relative == test.path

        candidate = File.join(root, relative)
        raise Error, "Test target is not a file" if File.lstat(candidate).symlink?
        path = File.realpath(candidate)
        prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
        raise Error, "Test target is outside the workspace" unless path.start_with?(prefix) && File.file?(path)

        command = case test.framework
        when :minitest then minitest_command(tests)
        when :rspec then rspec_command(tests)
        else raise Error, "Unknown test framework"
        end
        gemfile = File.join(root, "Gemfile")
        bundled = regular_file?(gemfile)
        command = [RbConfig.ruby, "-S", "bundle", "exec", *command] if bundled
        environment = unbundled_environment
        environment["BUNDLE_GEMFILE"] = gemfile if bundled
        {"label" => label(test), "command" => command.freeze, "cwd" => root,
         "env" => environment.freeze,
         "presentation" => {"panel" => "output", "reveal" => "silent"}.freeze}.freeze
      rescue SystemCallError, TypeError => error
        raise Error, "Cannot run test: #{error.message}"
      end

      def initialize(test, output, generation: nil, tests: [test])
        @test, @tests, @output, @generation = test, tests.dup.freeze, output, generation
        @bytes, @cancelled = +"".b, false
      end

      def append(bytes)
        return if bytes.nil? || bytes.empty?

        @bytes << bytes.b
        @bytes = @bytes.byteslice(-MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES) if @bytes.bytesize > MAX_OUTPUT_BYTES
        nil
      end

      def cancel = (@cancelled = true)

      def finish(status)
        return result(:skipped) if @cancelled
        return failure_result unless status&.success?

        count, skipped = summary
        return failure_result unless count == tests.length

        skipped == count ? result(:skipped) : result(:success)
      end

      private

      def self.minitest_command(tests)
        selectors = tests.map do |test|
          suite = test.groups.join("::")
          raise Error, "Minitest suite is unknown" if suite.empty?
          raise Error, "Minitest selector is unknown" unless test.selector

          "#{Regexp.escape(suite)}##{Regexp.escape(test.selector)}"
        end
        body = selectors.length == 1 ? selectors.first : "(?:#{selectors.join("|")})"
        filter = "\\A#{body}\\z"
        raise Error, "Minitest selector is too large" if filter.bytesize > MAX_FILTER_BYTES

        [RbConfig.ruby, "-Itest", tests.first.path, "--name", "/#{filter}/"]
      end

      def self.rspec_command(tests)
        patterns = tests.map do |test|
          raise Error, "RSpec selector is unknown" unless test.selector

          pattern = "\\A#{Regexp.escape(test.selector)}\\z"
          raise Error, "RSpec selector is too large" if pattern.bytesize > MAX_FILTER_BYTES
          pattern
        end
        size = patterns.sum { |pattern| "--example-matches".bytesize + pattern.bytesize + 2 }
        raise Error, "RSpec selectors are too large" if size > MAX_FILTER_BYTES

        filters = patterns.flat_map { |pattern| ["--example-matches", pattern] }
        test = tests.first
        [RbConfig.ruby, "-S", "rspec", "#{test.path}:#{test.line}", *filters,
         "--format", "progress", "--no-color"]
      end

      def self.label(test)
        name = test.path.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
          .each_char.map { |character| character.match?(/\s/) ? " " : character }.last(120).join
        digest = Digest::SHA256.hexdigest(test.path).slice(0, 16)
        "Test: #{name} [#{digest}]:#{test.line}:#{test.offset}"
      end

      def self.regular_file?(path)
        File.lstat(path).file? && !File.lstat(path).symlink?
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def self.unbundled_environment
        clean = if defined?(Bundler) && Bundler.respond_to?(:unbundled_env)
          Bundler.unbundled_env
        else
          ENV.to_h.reject { |key, _| key.start_with?("BUNDLE_") }
        end
        (ENV.keys | clean.keys).each_with_object({}) do |key, result|
          result[key] = clean[key] if ENV[key] != clean[key]
        end
      end
      private_class_method :minitest_command, :rspec_command, :label, :regular_file?, :unbundled_environment

      def failure_result
        path, line = failure_location || [test.path, test.line]
        result(:failure, path, line, "#{test.name} failed")
      end

      def summary
        summary = nil
        recent_output.each_line do |line|
          line = line.strip
          if test.framework == :minitest &&
              (match = line.match(/\A(\d+)\s+runs?,.*,[ \t]*(\d+)\s+skips?\z/i))
            summary = [match[1].to_i, match[2].to_i]
          elsif test.framework == :rspec &&
              (match = line.match(/\A(\d+)\s+examples?,[ \t]*0\s+failures?(?:,[ \t]*(\d+)\s+pending(?:\s+.*)?)?\z/i))
            summary = [match[1].to_i, match[2].to_s.to_i]
          end
        end
        summary || [nil, nil]
      end

      def failure_location
        relative = test.path.tr("\\", "/")
        candidates = ["./#{relative}", relative]
        recent_output.each_line do |line|
          normalized = line.tr("\\", "/")
          candidates.each do |path|
            cursor = normalized.index("#{path}:")
            next unless cursor
            number = normalized[cursor + path.length + 1, 12].to_s[/\A\d{1,10}/]
            value = number.to_i
            return [relative, value] if value.between?(1, Discovery::MAX_FILE_BYTES + 1)
          end
        end
        nil
      end

      def output_text
        @output_text ||= @bytes.gsub(ANSI, "").encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      end

      def recent_output
        text = output_text
        bytes, cursor = text.b, text.bytesize
        MAX_PARSE_LINES.times do
          index = cursor > 1 ? bytes.rindex("\n".b, cursor - 2) : nil
          unless index
            cursor = 0
            break
          end
          cursor = index + 1
        end
        text.byteslice(cursor..).force_encoding(Encoding::UTF_8)
      end

      def result(status, path = nil, line = nil, message = nil)
        Result.new(status, path, line, message&.byteslice(0, 4_096)&.scrub("")).freeze
      end
    end
  end
end
