# frozen_string_literal: true

module Canopus
  module TestRunner
    # Rejects byte-invalid names before Alkaid computes depth or consults ignores.
    class SafeWalker < Alkaid::Walker
      private

      def walk(directory, visited, &block)
        return if @cancelled&.call

        absolute_directory = absolute(directory)
        stat = File.stat(absolute_directory)
        return unless visited.add?([stat.dev, stat.ino])

        Dir.children(absolute_directory).sort.each do |name|
          return if @cancelled&.call
          next if name == ".git" || (!@hidden && name.start_with?("."))

          relative = directory.empty? ? name : File.join(directory, name)
          normalized = File::ALT_SEPARATOR ? relative.tr(File::ALT_SEPARATOR, "/") : relative
          normalized = TestRunner.normalize_path(normalized)
          next unless normalized

          depth = normalized.count("/") + 1
          next if @max_depth && depth > @max_depth

          visit(relative, normalized, depth, visited, &block)
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR, ArgumentError, EncodingError
          next
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
        nil
      end
    end
  end
end
