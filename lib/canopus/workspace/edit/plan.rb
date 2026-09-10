# frozen_string_literal: true

require "set"
require_relative "../edit"
require_relative "node"
require_relative "resource_preparable"
require_relative "executable"

module Canopus
  module Workspace::Edit
    # Resource edits are uncommon and explicitly confirmed. No filesystem mutation
    # happens until every ordered resource/text operation has passed preflight.
    class Plan
      include ResourcePreparable
      include Executable

      def initialize(workspace, edit)
        @workspace, @root = workspace, workspace.root
        @nodes, @observed, @originals = {}, {}, {}
        @operations, @new_buffers, @recoveries, @journal = [], [], [], []
        @text_bytes = @edit_count = 0
        changes = edit.fetch("documentChanges")
        raise Error, "invalid documentChanges" unless changes.is_a?(Array) && changes.length <= 10_000
        changes.each_with_index do |change, index|
          @failed_change = index
          raise Error, "invalid workspace change" unless change.is_a?(Hash)
          change["kind"] ? prepare_resource(change, index) : prepare_text(change, index)
        end
        @failed_change = nil
      rescue StandardError
        close
        raise
      end

      def close
        @new_buffers.each { |buffer| buffer.close unless @workspace.buffers.value?(buffer) }
      end

      private

      def local_path(uri)
        raise Error, "resource URI is too long" unless uri.is_a?(String) && uri.bytesize <= 16_384
        path = File.expand_path(LSP::Protocol.path(uri))
        raise Error, "resource path is too long" if path.bytesize > 4_096
        unless path.start_with?(@root + File::SEPARATOR)
          parent, pieces = File.dirname(path), [File.basename(path)]
          until File.directory?(parent)
            pieces.unshift(File.basename(parent))
            parent = File.dirname(parent)
          end
          path = File.join(File.realpath(parent), *pieces)
        end
        raise Error, "language server resource is outside project" unless path.start_with?(@root + File::SEPARATOR)
        pieces = path.delete_prefix(@root + File::SEPARATOR).split(File::SEPARATOR)
        raise Error, "language server cannot modify Git metadata or recovery files" if protected_path?(path)
        parent = @root
        pieces[0...-1].each do |piece|
          parent = File.join(parent, piece)
          node = node_at(parent)
          raise Error, "resource parent does not exist or follows a symlink" unless node&.exists && node.kind == :directory
        end
        path
      end

      def protected_path?(path)
        pieces = path.delete_prefix(@root + File::SEPARATOR).split(File::SEPARATOR).map(&:downcase)
        pieces.include?(".git") || pieces.each_cons(2).any? { |pair| pair == %w[.canopus trash] }
      end

      def node_at(path)
        return @nodes[path] if @nodes.key?(path)
        raise Error, "workspace edit exceeds 100000 filesystem entries" if @nodes.length >= 100_000
        stat = File.lstat(path) rescue nil
        buffer = @workspace.buffers[path]
        @observed[path] = fingerprint(path)
        return @nodes[path] = nil unless stat || buffer
        kind = if stat&.symlink? then :symlink
        elsif stat&.directory? then :directory
        elsif !stat || stat.file? then :file
        else :special
        end
        raise Error, "special files are not workspace edit targets" if kind == :special
        @nodes[path] = Node.new(origin: stat && path, path: path, kind: kind, exists: !!stat, buffer: buffer, edits: [])
      end

      def fingerprint(path)
        stat = File.lstat(path)
        [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime]
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def subtree(path)
        first = node_at(path)
        return [] unless first
        pending, result, seen = [first], [], {}
        until pending.empty?
          node = pending.pop
          next if seen[node.object_id]
          seen[node.object_id] = true
          result << node
          raise Error, "resource operation exceeds 100000 entries" if result.length > 100_000
          if node.kind == :directory && node.origin
            Dir.children(node.origin).each do |name|
              child_path = File.join(node.path, name)
              raise Error, "resource operation includes protected metadata" if protected_path?(child_path)
              unless @nodes.key?(child_path)
                origin = File.join(node.origin, name)
                child = node_at(origin)
                @nodes[child_path] = child
                child.path = child_path if child
              end
              pending << @nodes[child_path] if @nodes[child_path]
            end
          end
        end
        # Include unsaved documents under a directory even if they have no disk entry.
        @workspace.buffers.keys.grep(String).each do |candidate|
          next unless candidate.start_with?(path + File::SEPARATOR)
          node = node_at(candidate)
          result << node if node && !seen[node.object_id]
          seen[node.object_id] = true if node
        end
        @nodes.each_value do |node|
          next unless node && node.path.start_with?(path + File::SEPARATOR) && !seen[node.object_id]
          result << node
          seen[node.object_id] = true
        end
        result
      end

      def buffer_for(node)
        return node.buffer if node.rope
        unless node.buffer
          node.buffer = node.origin ? Buffer.open(node.origin) : Buffer.new("", path: node.path)
          @new_buffers << node.buffer
        end
        buffer = node.buffer
        @originals[buffer] ||= [buffer.rope, buffer.version, buffer.path]
        node.rope, node.version = buffer.rope, buffer.version
        buffer
      end

      def prepare_text(change, index)
        document, edits = change.values_at("textDocument", "edits")
        raise Error, "invalid text document edit" unless document.is_a?(Hash) && edits.is_a?(Array)
        path = local_path(document.fetch("uri"))
        node = node_at(path)
        raise Error, "text edit target does not exist or is a symlink" unless node && node.kind == :file
        buffer = buffer_for(node)
        raise Error, "cannot edit a read-only document" if buffer.read_only
        version = document["version"]
        raise Error, "language server edit has stale document version" unless version.nil? || (version.is_a?(Integer) && version == node.version)
        changes = edits.map do |entry|
          unless entry.is_a?(Hash) && entry["range"].is_a?(Hash) && entry["newText"].is_a?(String) && entry["newText"].valid_encoding?
            raise Error, "invalid LSP text edit"
          end
          @text_bytes += entry["newText"].bytesize
          @edit_count += 1
          raise Error, "workspace edit text exceeds safety limits" if @text_bytes > (32 << 20) || @edit_count > 100_000
          range = entry.fetch("range")
          [LSP::Protocol.offset(node.rope, range.fetch("start"))...LSP::Protocol.offset(node.rope, range.fetch("end")), entry.fetch("newText")]
        end
        node.rope = node.rope.apply_edits(changes)
        node.version += 1 unless changes.empty?
        node.edits << [changes, index] unless changes.empty?
      end
    end
  end
end
