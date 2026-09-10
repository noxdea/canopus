# frozen_string_literal: true

require "securerandom"

module Canopus
  module Workspace::ProjectTreeEditable
    def project_tree
      files
      @project_tree ||= Project::Tree.new(@project_entries || [], expanded: @expanded_directories ||= Set.new).tap do |tree|
        tree.reveal(editor.buffer.path.delete_prefix(@root + File::SEPARATOR)) if editor&.buffer&.path
      end
    end
    def project_path(relative)
      path = @project.path(relative)
      parent = path
      parent = File.dirname(parent) until File.exist?(parent) || File.symlink?(parent)
      actual = File.realpath(parent)
      raise Error, "project operation follows a symlink outside the project" unless actual == @root || actual.start_with?(@root + File::SEPARATOR)
      raise Error, "cannot modify project root or Git metadata" if path == @root || path.delete_prefix(@root + "/").split("/").include?(".git")
      path
    end
    def create_project_entry(relative, directory: false)
      path = project_path(relative)
      raise Error, "path already exists" if File.exist?(path) || File.symlink?(path)
      directory ? Dir.mkdir(path) : File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644, &:close)
      refresh_files
      open(path) unless directory
      path
    end
    def rename_project_entry(relative, destination)
      source, target = project_path(relative), project_path(destination)
      raise Error, "source does not exist" unless File.exist?(source) || File.symlink?(source)
      raise Error, "destination exists" if File.exist?(target) || File.symlink?(target)
      raise Error, "cannot move a directory inside itself" if target.start_with?(source + File::SEPARATOR)
      if @buffers.values.any? { |buffer| buffer.path && (buffer.path == target || buffer.path.start_with?(target + File::SEPARATOR)) }
        raise Error, "destination is open in another buffer"
      end
      File.rename(source, target)
      invalidate_git
      @buffers.keys.grep(String).each do |old|
        next unless old == source || old.start_with?(source + File::SEPARATOR)
        buffer = @buffers.delete(old)
        new_path = target + old.delete_prefix(source)
        begin
          close_language_documents(buffer)
        rescue StandardError => error
          @message = "Path moved; language server close failed: #{error.message}"
          @opened_lsp_documents&.delete_if { |(_, document), _| document.equal?(buffer) }
        end
        buffer.relocate(new_path)
        @buffers[new_path] = buffer
        @panes.each do |pane|
          pane.editors.each do |current|
            next unless current.buffer.equal?(buffer)
            current.language = definition_for(new_path)
            apply_editor_settings(current)
          end
        end
      end
      refresh_files
      target
    end
    # Deletion is recoverable and never follows directory symlinks.
    def trash_project_entry(relative)
      source = @project.path(relative)
      raise Error, "cannot trash project root or Git metadata" if source == @root || relative.split("/").include?(".git")
      raise Error, "cannot trash the recovery directory" if source == @project.path(".canopus") || source == @project.path(".canopus/trash")
      affected = @buffers.values.select { |buffer| buffer.path && (buffer.path == source || buffer.path.start_with?(source + File::SEPARATOR)) }
      raise Error, "save or discard changes before deleting this path" if affected.any?(&:dirty?)
      parent = File.realpath(File.dirname(source))
      raise Error, "path outside project" unless parent == @root || parent.start_with?(@root + File::SEPARATOR)
      trash = @project.path(".canopus/trash")
      project_path(".canopus/trash")
      FileUtils.mkdir_p(trash)
      destination = File.join(trash, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}-#{File.basename(source)}")
      File.rename(source, destination)
      @message = "Moved to #{destination}; recoverable by moving it back"
      refresh_files
      destination
    end
  end
end
