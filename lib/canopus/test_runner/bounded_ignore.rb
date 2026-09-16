# frozen_string_literal: true

module Canopus
  module TestRunner
    # Loads ignore files only for directories the bounded walker reaches.
    class BoundedIgnore
      MAX_FILES = 1_000
      MAX_FILE_BYTES = 256 * 1_024
      MAX_TOTAL_BYTES = 1 << 20
      MAX_LINES = 10_000
      MAX_LINE_BYTES = 4_096
      MAX_GIT_POINTER_BYTES = 4_096

      def initialize(root, delegate: nil, cancelled: -> { false })
        @root = root
        @delegate = delegate
        @cancelled = cancelled
        @matcher = Thuban::IgnoreMatcher.new.add("/.canopus/trash/\n")
        @loaded = {}
        @files = @bytes = @lines = 0
      end

      def ignored?(path, directory: false)
        path = TestRunner.normalize_path(path)
        return true unless path
        return true if @cancelled.call
        return safe_delegate(path, directory) if @delegate

        bases_for(path).each do |base|
          break if @cancelled.call
          load_base(base)
        end
        return true if @cancelled.call

        @matcher.ignored?(path, directory: directory)
      rescue ArgumentError, EncodingError
        true
      end

      private

      def safe_delegate(path, directory)
        @delegate.ignored?(path, directory: directory) || @matcher.ignored?(path, directory: directory)
      rescue ArgumentError, EncodingError
        true
      end

      def bases_for(path)
        pieces = path.split("/")[0...-1]
        ["", *pieces.each_index.map { |index| pieces[0..index].join("/") }]
      end

      def load_base(base)
        return if @loaded[base]
        @loaded[base] = true
        load_repository_exclude if base.empty?
        %w[.gitignore .ignore].each do |name|
          break if @cancelled.call
          load_file(File.join(@root, *base.split("/"), name), base, within: @root)
        end
      end

      def load_repository_exclude
        common = repository_common_directory
        load_file(File.join(common, "info", "exclude"), "", within: common) if common
      end

      def repository_common_directory
        git = File.join(@root, ".git")
        entry = File.lstat(git)
        return if entry.symlink?
        git_directory = if entry.directory?
          File.realpath(git)
        elsif entry.file? && (pointer = control_file(git, within: @root))&.start_with?("gitdir: ")
          real_directory(File.expand_path(pointer.delete_prefix("gitdir: "), @root))
        end
        return unless git_directory

        common_file = File.join(git_directory, "commondir")
        common = control_file(common_file, within: git_directory)
        common ? real_directory(File.expand_path(common, git_directory)) : git_directory
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
        nil
      end

      def real_directory(path)
        entry = File.lstat(path)
        return if entry.symlink? || !entry.directory?

        File.realpath(path)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
        nil
      end

      def control_file(path, within:)
        entry = File.lstat(path)
        return if entry.symlink? || !entry.file? || entry.size > MAX_GIT_POINTER_BYTES
        absolute = File.realpath(path)
        return unless inside?(absolute, within)

        source = File.open(absolute, "rb") { |file| file.read(MAX_GIT_POINTER_BYTES + 1) }
        return if source.bytesize > MAX_GIT_POINTER_BYTES || source.include?("\0")
        source = source.force_encoding(Encoding::UTF_8)
        source.strip if source.valid_encoding?
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, EncodingError
        nil
      end

      def load_file(path, base, within:)
        return if @files >= MAX_FILES || @bytes >= MAX_TOTAL_BYTES || @lines >= MAX_LINES
        entry = File.lstat(path)
        return if entry.symlink? || !entry.file? || entry.size > MAX_FILE_BYTES
        absolute = File.realpath(path)
        return unless inside?(absolute, within)

        available = [MAX_FILE_BYTES, MAX_TOTAL_BYTES - @bytes].min
        source = File.open(absolute, "rb") { |file| file.read(available + 1) }
        return if source.bytesize > available || source.include?("\0")
        source = source.force_encoding(Encoding::UTF_8)
        return unless source.valid_encoding?

        kept = +""
        source.each_line do |line|
          break if @cancelled.call || @lines >= MAX_LINES
          next if line.bytesize > MAX_LINE_BYTES
          kept << line
          @lines += 1
        end
        @matcher = @matcher.add(kept, base: base) unless kept.empty? || @cancelled.call
        @files += 1
        @bytes += source.bytesize
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, EncodingError
        nil
      end

      def inside?(path, directory)
        directory = File.realpath(directory)
        path == directory || path.start_with?(directory + File::SEPARATOR)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
        false
      end
    end
  end
end
