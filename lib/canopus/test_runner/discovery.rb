# frozen_string_literal: true

module Canopus
  module TestRunner
    class Discovery
      MAX_FILES = 50_000
      MAX_TEST_FILES = 2_000
      MAX_FILE_BYTES = 1 << 20
      MAX_TESTS = 10_000
      MAX_DEPTH = 64
      MAX_PATH_BYTES = TestRunner::MAX_PATH_BYTES
      MAX_ADAPTERS = 16
      MAX_NAME_BYTES = 4_096
      MAX_GROUPS = 32

      attr_reader :root

      def initialize(root:, ignore: nil, adapters: [Minitest.new, RSpec.new])
        @root = File.realpath(root)
        raise ArgumentError, "test root must be a directory" unless File.directory?(@root)
        raise ArgumentError, "ignore must respond to ignored?" if ignore && !ignore.respond_to?(:ignored?)
        unless adapters.is_a?(Array) && !adapters.empty? && adapters.length <= MAX_ADAPTERS &&
            adapters.all? { |adapter| adapter.respond_to?(:candidate?) && adapter.respond_to?(:discover) }
          raise ArgumentError, "test adapters must support candidate? and discover"
        end

        @ignore, @adapters = ignore, adapters.dup.freeze
      end

      def discover(cancelled: -> { false })
        raise ArgumentError, "cancelled must respond to call" unless cancelled.respond_to?(:call)

        require "prism"
        tests, files, candidates = [], 0, 0
        ignore = BoundedIgnore.new(root, delegate: @ignore, cancelled: cancelled)
        walker = SafeWalker.new(root, ignore: ignore, hidden: true,
          follow_symlinks: false, max_depth: MAX_DEPTH, cancelled: cancelled)
        walker.each do |relative|
          break if cancelled.call || (files += 1) > MAX_FILES || tests.length >= MAX_TESTS
          relative = TestRunner.normalize_path(relative)
          next unless relative

          adapters = @adapters.select { |adapter| adapter.candidate?(relative) }
          next if adapters.empty?
          break if (candidates += 1) > MAX_TEST_FILES

          source = test_source(relative)
          next unless source
          parsed = Prism.parse(source)
          next unless parsed.success?

          adapters.each do |adapter|
            remaining = MAX_TESTS - tests.length
            break if remaining <= 0 || cancelled.call
            discovered = adapter.discover(parsed.value, path: relative, limit: remaining, cancelled: cancelled)
            next unless discovered.is_a?(Array)
            discovered.first(remaining).each { |test| tests << test if valid_test?(test, relative) }
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, EncodingError, ArgumentError
          next
        end
        tests.sort_by! { |test| [test.path, test.line, test.column, test.framework.to_s, test.name] }
        tests.freeze
      end

      private

      def valid_test?(test, relative)
        test.is_a?(Test) && test.path == relative && [:minitest, :rspec].include?(test.framework) &&
          valid_name?(test.name) && test.groups.is_a?(Array) && test.groups.length <= MAX_GROUPS &&
          test.groups.all? { |group| valid_name?(group) } &&
          test.line.is_a?(Integer) && test.line.positive? &&
          [test.column, test.offset].all? { |value| value.is_a?(Integer) && value >= 0 } &&
          valid_name?(test.selector)
      end

      def valid_name?(value)
        value.is_a?(String) && value.valid_encoding? && !value.include?("\0") && value.bytesize <= MAX_NAME_BYTES
      end

      def test_source(relative)
        candidate = File.join(root, relative)
        entry = File.lstat(candidate)
        return if entry.symlink? || !entry.file? || entry.size > MAX_FILE_BYTES

        absolute = File.realpath(candidate)
        prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
        return unless absolute.start_with?(prefix)

        source = File.open(absolute, "rb") { |file| file.read(MAX_FILE_BYTES + 1) }
        return if source.bytesize > MAX_FILE_BYTES || source.include?("\0")
        source = source.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8)
        source if source.valid_encoding?
      end
    end
  end
end
