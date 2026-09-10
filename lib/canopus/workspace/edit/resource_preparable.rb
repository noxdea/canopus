# frozen_string_literal: true

module Canopus
  module Workspace::Edit
    module ResourcePreparable
      private

      def prepare_resource(change, index)
        options = change.fetch("options", {})
        unless options.is_a?(Hash) && options.values.all? { |value| value == true || value == false }
          raise Error, "invalid resource operation options"
        end
        case change["kind"]
        when "create" then prepare_create(change, options, index)
        when "rename" then prepare_rename(change, options, index)
        when "delete" then prepare_delete(change, options, index)
        else raise Error, "unknown resource operation"
        end
      end

      def protect_buffers(nodes, destination: false)
        nodes.each do |node|
          buffer = node.buffer
          @originals[buffer] ||= [buffer.rope, buffer.version, buffer.path] if buffer
          raise Error, "save or discard changes before deleting or overwriting a resource" if !node.edits.empty? || buffer&.dirty? || buffer&.read_only
          raise Error, "close the destination document before overwriting it" if destination && buffer
          if buffer && @workspace.buffers.values.grep(MultiBuffer).any? { |multi| multi.excerpts.any? { |excerpt| excerpt.buffer.equal?(buffer) } }
            raise Error, "close excerpt views before deleting a source resource"
          end
        end
      end

      def prepare_create(change, options, index)
        path = local_path(change.fetch("uri"))
        previous = node_at(path)
        return if previous&.exists && options["ignoreIfExists"] && !options["overwrite"]
        raise Error, "resource already exists" if previous&.exists && !options["overwrite"]
        raise Error, "cannot replace a directory or symlink with a file" if previous&.exists && previous.kind != :file
        protect_buffers([previous].compact)
        # A trailing slash explicitly denotes a directory URI.
        kind = change.fetch("uri").end_with?("/") ? :directory : :file
        raise Error, "cannot replace a file with a directory" if kind == :directory && previous&.exists
        node = Node.new(path: path, kind: kind, exists: true, buffer: previous&.buffer, edits: [])
        if node.buffer
          buffer_for(node)
          node.reset = true
          node.version += 1 unless node.rope.empty?
          node.rope = Denebola::Rope.new("")
        end
        @nodes[path] = node
        @operations << {kind: :create, path: path, directory: kind == :directory, backup: !!previous&.exists, index: index}
      end

      def prepare_rename(change, options, index)
        source, target = local_path(change.fetch("oldUri")), local_path(change.fetch("newUri"))
        node = node_at(source)
        raise Error, "rename source does not exist" unless node&.exists
        if source == target || target.start_with?(source + File::SEPARATOR) || source.start_with?(target + File::SEPARATOR)
          raise Error, "cannot move a resource into itself or overwrite its ancestor"
        end
        previous = node_at(target)
        return if previous&.exists && options["ignoreIfExists"] && !options["overwrite"]
        raise Error, "rename destination exists" if previous&.exists && !options["overwrite"]
        destination_nodes = subtree(target)
        protect_buffers(destination_nodes, destination: true)
        moving = subtree(source)
        moving.each do |entry|
          buffer_for(entry) if entry.buffer
          destination = target + entry.path.delete_prefix(source)
          other = @nodes[destination] || @workspace.buffers[destination]
          raise Error, "rename destination has an open document" if other && !destination_nodes.include?(other) && !moving.include?(other)
        end
        destination_nodes.each { |entry| @nodes[entry.path] = nil }
        moving.each do |entry|
          old = entry.path
          entry.path = target + old.delete_prefix(source)
          @nodes[old] = nil
          @nodes[entry.path] = entry
        end
        @operations << {kind: :rename, source: source, path: target, backup: !!previous&.exists, index: index}
      end

      def prepare_delete(change, options, index)
        path = local_path(change.fetch("uri"))
        node = node_at(path)
        return if !node&.exists && options["ignoreIfNotExists"]
        raise Error, "delete target does not exist" unless node&.exists
        removed = subtree(path)
        if node.kind == :directory && removed.any? { |entry| entry != node && entry.exists } && !options["recursive"]
          raise Error, "recursive deletion must be explicit for nonempty directories"
        end
        protect_buffers(removed)
        removed.each { |entry| @nodes[entry.path] = nil }
        @operations << {kind: :delete, path: path, nodes: removed, index: index}
      end
    end
  end
end
