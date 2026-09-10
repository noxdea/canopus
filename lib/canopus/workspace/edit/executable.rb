# frozen_string_literal: true

module Canopus
  module Workspace::Edit
    module Executable
      def apply
        return {"applied" => false, "failureReason" => "workspace edit plan has already been used"} if @used
        @used = true
        verify_unchanged
        @operations.each do |operation|
          @failed_change = operation[:index]
          execute_resource(operation)
        end
        # All text edits were checked against the ordered virtual filesystem. They
        # remain unsaved buffer edits; no temporary draft is written into a file.
        @memory_started = true
        @failed_change = nil
        update_buffers
        @workspace.refresh_files
        result = {"applied" => true}
        result["recoveryPaths"] = @recoveries.dup unless @recoveries.empty?
        announce_recovery
        result
      rescue StandardError => error
        failures = @memory_started ? [] : rollback
        announce_recovery
        result = {"applied" => false, "failureReason" => ([error.message] + failures).join("; "),
          "recoveryPaths" => @recoveries.select { |path| File.exist?(path) || File.symlink?(path) }}
        result["failureReason"] += "; recoverable files: #{File.join(@root, '.canopus', 'trash')}" unless result["recoveryPaths"].empty?
        result["failedChange"] = @failed_change if @failed_change
        result
      ensure
        close
      end

      private

      def verify_unchanged
        raise Error, "resource changed while preparing workspace edit" unless @observed.all? { |path, value| fingerprint(path) == value }
        unless @originals.all? { |buffer, (rope, version, path)| buffer.rope.equal?(rope) && buffer.version == version && buffer.path == path }
          raise Error, "document changed while preparing workspace edit"
        end
      end

      def recovery_path(path)
        @workspace.project_path(".canopus/trash")
        directory = File.join(@root, ".canopus", "trash")
        FileUtils.mkdir_p(directory)
        name = File.basename(path).byteslice(0, 160).scrub
        File.join(directory, "lsp-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(8)}-#{name}")
      end

      def backup(path)
        destination = recovery_path(path)
        File.rename(path, destination)
        @recoveries << destination
        @journal << [:restore, destination, path]
        destination
      end

      def execute_resource(operation)
        path = operation.fetch(:path)
        [path, operation[:source]].compact.each do |target|
          parent = File.realpath(File.dirname(target))
          raise Error, "resource parent moved outside project" unless parent == @root || parent.start_with?(@root + File::SEPARATOR)
        end
        backup(path) if operation[:backup]
        case operation[:kind]
        when :create
          operation[:directory] ? Dir.mkdir(path) : File.open(path, File::CREAT | File::EXCL | File::WRONLY, 0o644, &:close)
          @journal << [:created, path]
        when :rename
          raise Error, "rename destination appeared during workspace edit" if File.exist?(path) || File.symlink?(path)
          File.rename(operation.fetch(:source), path)
          @journal << [:restore, path, operation.fetch(:source)]
        when :delete then backup(path)
        end
      end

      def rollback
        failures = []
        @journal.reverse_each do |kind, source, target|
          next unless File.exist?(source) || File.symlink?(source)
          if kind == :created
            target = recovery_path(source)
            @recoveries << target
          elsif File.exist?(target) || File.symlink?(target)
            raise Error, "rollback destination now exists: #{target}"
          end
          File.rename(source, target)
        rescue StandardError => error
          failures << "recovery required: #{error.message}"
        end
        failures
      end

      def update_buffers
        deleted = @operations.select { |operation| operation[:kind] == :delete }.flat_map { |operation| operation[:nodes] }.filter_map(&:buffer)
        deleted.uniq.each do |buffer|
          @workspace.panes.flat_map(&:editors).select { |editor| editor.buffer.equal?(buffer) }.each { |editor| @workspace.close_editor(editor, discard: true) }
          @workspace.close_language_documents(buffer)
          @workspace.buffers.delete_if { |_, value| value.equal?(buffer) }
          buffer.close
        end
        @nodes.values.compact.uniq.each do |node|
          buffer = node.buffer
          next unless buffer
          if buffer.path != node.path
            @workspace.invalidate_git
            @workspace.close_language_documents(buffer)
            @workspace.buffers.delete_if { |_, value| value.equal?(buffer) }
            buffer.relocate(node.path)
            @workspace.panes.flat_map(&:editors).each do |editor|
              next unless editor.buffer.equal?(buffer)
              editor.language = @workspace.send(:definition_for, node.path)
              @workspace.send(:apply_editor_settings, editor)
            end
          end
          @workspace.buffers[node.path] = buffer
          buffer.reload if node.reset || (node.origin.nil? && node.exists)
          buffer.begin_undo_group
          begin
            node.edits.each do |changes, index|
              @failed_change = index
              buffer.edit(changes, kind: :lsp)
            end
          ensure
            buffer.end_undo_group
          end
        end
      end

      def announce_recovery
        paths = @recoveries.select { |path| File.exist?(path) || File.symlink?(path) }
        @workspace.message = "Language server resource backups: #{paths.join(', ')}" unless paths.empty?
      end
    end
  end
end
