# frozen_string_literal: true

module Canopus
  module Git
    class State
      CACHE_LIMIT = 20
      Snapshot = Data.define(:head, :branch, :index_stamp, :entries) do
        def identity = [head, branch, index_stamp].freeze
      end

      attr_reader :snapshot

      def initialize(repository)
        @repository = repository
        @repository_lock = Mutex.new
        @diff_cache = {}
      end

      def capture
        synchronize do |repository|
          3.times do
            before = repository_identity
            entries = repository.status.to_h do |entry|
              [entry.path.dup.freeze, entry.code.dup.freeze]
            end.freeze
            after = repository_identity
            return Snapshot.new(*after, entries) if before == after
          end
          raise Thuban::RefLockError, "Git HEAD or index changed while reading status"
        end
      end

      def identity
        synchronize do |repository|
          [freeze_string(repository.head), freeze_string(repository.branch), index_stamp(repository)].freeze
        end
      end

      def install(snapshot)
        raise ArgumentError, "invalid Git snapshot" unless snapshot.is_a?(Snapshot)

        @snapshot = snapshot
      end

      def invalidate
        @snapshot = nil
        @diff_cache.clear
      end

      def cached_diff(key) = @diff_cache[key]

      def store_diff(key, diff)
        @diff_cache.clear if @diff_cache.length >= CACHE_LIMIT && !@diff_cache.key?(key)
        @diff_cache[key] = diff
      end

      def synchronize(snapshot: nil, index_lock: false, &block)
        @repository_lock.synchronize do
          operation = lambda do
            if snapshot && snapshot.identity != repository_identity
              raise Thuban::RefLockError, "Git HEAD or index changed since it was displayed"
            end

            block.call(@repository)
          end
          index_lock ? with_index_lock(&operation) : operation.call
        end
      end

      private

      def freeze_string(value) = value&.dup&.freeze

      def index_stamp(repository)
        path = File.join(repository.git_dir, "index")
        return unless File.file?(path)

        stat = File.stat(path)
        [stat.mtime.to_i, stat.mtime.nsec, stat.size, stat.ino].freeze
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def repository_identity
        [freeze_string(@repository.head), freeze_string(@repository.branch), index_stamp(@repository)].freeze
      end

      def with_index_lock
        path = File.join(@repository.git_dir, "index.lock")
        lock = File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
        yield
      rescue Errno::EEXIST
        raise Thuban::RefLockError, "Git index is locked: #{path}"
      ensure
        lock&.close
        File.unlink(path) if lock && File.exist?(path)
      end
    end
  end
end
