# frozen_string_literal: true

require "digest"
require "json"
require "tempfile"

module Canopus
  module Workspace::PersistentUndo
    MAX_FILE_BYTES = 16 * 1024 * 1024
    MAX_PROJECT_BYTES = 256 * 1024 * 1024
    RECORD_NAME = /\A[0-9a-f]{64}\.json\z/

    def persistent_undo_directory
      File.join(@root, ".canopus", "undo")
    end

    def load_persistent_undo(buffer)
      return false unless persistent_undo_enabled? && persistent_undo_eligible?(buffer)
      path = persistent_undo_record_path(buffer.path)
      return false unless path && File.file?(path) && !File.symlink?(path)
      return false if File.size(path) > MAX_FILE_BYTES
      record = JSON.parse(File.binread(path), max_nesting: 100)
      return false unless persistent_undo_record_valid?(record, buffer, path)
      buffer.restore_persistent_undo!(record)
    rescue StandardError
      false
    end

    def save_persistent_undo(buffer)
      return false unless persistent_undo_enabled? && persistent_undo_eligible?(buffer)
      record_path = persistent_undo_record_path(buffer.path)
      return false unless record_path && persistent_undo_directory_ready?
      record = buffer.persistent_undo_record(max_entries: @settings["persistent_undo"]["max_entries"])
      unless record
        persistent_undo_delete(record_path)
        return true
      end
      stat = File.stat(buffer.path)
      digest = buffer.disk_digest || Digest::SHA256.file(buffer.path).hexdigest
      record.merge!("version" => 1, "project_root" => @root,
        "relative_path" => persistent_undo_relative_path(buffer.path), "saved_at" => Time.now.to_i,
        "file" => {"size" => stat.size, "digest" => digest, "dev" => stat.dev, "ino" => stat.ino})
      payload = JSON.generate(record)
      return false if stat.size > MAX_FILE_BYTES || payload.bytesize > MAX_FILE_BYTES
      persistent_undo_make_room(record_path, payload.bytesize)
      return false if persistent_undo_project_bytes(except: record_path) + payload.bytesize > MAX_PROJECT_BYTES
      Tempfile.create([".undo-", ".json"], persistent_undo_directory, binmode: true) do |file|
        file.chmod(0o600)
        file.write(payload)
        file.flush
        file.fsync
        file.close
        File.rename(file.path, record_path)
      end
      true
    rescue StandardError
      false
    end

    private

    def mark_persistent_undo_path(buffer, path)
      expanded = File.expand_path(path, @root)
      buffer.instance_variable_set(:@persistent_undo_ineligible, true) if File.symlink?(expanded)
    rescue SystemCallError
      buffer.instance_variable_set(:@persistent_undo_ineligible, true)
    end

    def persistent_undo_enabled?
      persistent = @settings["persistent_undo"]
      persistent.is_a?(Hash) && persistent["enabled"] == true
    end

    def persistent_undo_eligible?(buffer)
      buffer.is_a?(Buffer) && !buffer.is_a?(MultiBuffer) && !buffer.instance_variable_get(:@persistent_undo_ineligible) && buffer.path && !buffer.read_only && !buffer.dirty? &&
        persistent_undo_relative_path(buffer.path) && File.file?(buffer.path) && !File.symlink?(buffer.path)
    end

    def persistent_undo_relative_path(path)
      absolute = File.expand_path(path)
      return unless absolute.start_with?("#{@root}#{File::SEPARATOR}")
      return unless File.realpath(absolute) == absolute
      absolute.delete_prefix("#{@root}#{File::SEPARATOR}").then { |relative| relative unless relative.empty? || relative.start_with?("..#{File::SEPARATOR}") }
    rescue SystemCallError
      nil
    end

    def persistent_undo_record_path(path)
      relative = persistent_undo_relative_path(path)
      return unless relative
      key = Digest::SHA256.hexdigest("#{@root}\0#{relative}")
      File.join(persistent_undo_directory, "#{key}.json")
    end

    def persistent_undo_directory_ready?
      base = File.join(@root, ".canopus")
      return false if File.symlink?(base)
      FileUtils.mkdir_p(base)
      return false unless File.directory?(base) && !File.symlink?(base)
      directory = persistent_undo_directory
      return false if File.symlink?(directory)
      FileUtils.mkdir_p(directory)
      return false unless File.directory?(directory) && !File.symlink?(directory)
      File.chmod(0o700, directory)
      true
    rescue SystemCallError
      false
    end

    def persistent_undo_record_valid?(record, buffer, record_path)
      return false unless record.is_a?(Hash) && record["version"] == 1 && record["project_root"] == @root
      relative = persistent_undo_relative_path(buffer.path)
      return false unless relative && record["relative_path"] == relative
      return false unless File.basename(record_path) == File.basename(persistent_undo_record_path(buffer.path))
      saved_at = record["saved_at"]
      return false unless saved_at.is_a?(Integer) && saved_at >= 0
      expire_days = @settings["persistent_undo"]["expire_days"]
      return false if saved_at < Time.now.to_i - expire_days * 86_400
      file = record["file"]
      return false unless file.is_a?(Hash)
      stat = File.lstat(buffer.path)
      return false unless stat.file? && !File.symlink?(buffer.path)
      return false unless file["size"] == stat.size && stat.size <= MAX_FILE_BYTES
      return false unless file["dev"] == stat.dev && file["ino"] == stat.ino
      digest = file["digest"]
      return false unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      return false unless digest == Digest::SHA256.file(buffer.path).hexdigest && digest == buffer.disk_digest
      history = record["history"]
      history.is_a?(Array) && history.length.between?(1, @settings["persistent_undo"]["max_entries"])
    rescue StandardError
      false
    end

    def persistent_undo_files
      return [] unless persistent_undo_directory_ready?
      Dir.children(persistent_undo_directory).filter_map do |name|
        next unless name.match?(RECORD_NAME)
        path = File.join(persistent_undo_directory, name)
        next unless File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_FILE_BYTES
        [path, File.mtime(path).to_i]
      rescue SystemCallError
        nil
      end
    rescue SystemCallError
      []
    end

    def persistent_undo_project_bytes(except: nil)
      persistent_undo_files.sum { |path, _| path == except ? 0 : File.size(path) }
    rescue SystemCallError
      MAX_PROJECT_BYTES
    end

    def persistent_undo_make_room(record_path, required)
      persistent_undo_files.reject { |path, _| path == record_path }.sort_by(&:last).each do |path, _|
        break if persistent_undo_project_bytes(except: record_path) + required <= MAX_PROJECT_BYTES
        persistent_undo_delete(path)
      end
    end

    def persistent_undo_delete(path)
      return false unless File.file?(path) && !File.symlink?(path)
      File.delete(path)
      true
    rescue SystemCallError
      false
    end
  end
end
