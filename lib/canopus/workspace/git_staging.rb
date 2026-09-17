# frozen_string_literal: true

require "zaniah/ui"

module Canopus
  module Workspace::GitStaging
    SCM_SECTIONS = {staged: "Staged", unstaged: "Changes", untracked: "Untracked"}.freeze

    def scm_tree
      return @scm_tree if @scm_tree

      @scm_tree = Zaniah::UI::TreeView.new(scm_nodes, height: 600).on_select do |change, event, _context|
        select_scm_change(change, event)
      end
      SCM_SECTIONS.each_key { |kind| @scm_tree.expand([:scm_section, kind]) }
      refresh_scm
      @scm_tree
    end

    def refresh_scm
      entries = git_status
      @scm_tree&.replace(scm_nodes(entries))
      @panels.badge("scm", entries.empty? ? nil : entries.length) if @panels&.key?("scm")
      @window&.request_frame
      nil
    end

    def stage_git_file(path = nil)
      path ||= selected_scm_path(:unstaged, :untracked)
      state = git_state
      raise Error, "Not a Git repository" unless state

      state.synchronize do |repository|
        index = repository.index
        absolute = repository.worktree_path(path)
        if File.exist?(absolute) || File.symlink?(absolute)
          stat = File.lstat(absolute)
          if stat.directory?
            entry = index[path] || repository.tree[path]
            raise Error, "Git submodule is not initialized: #{path}" unless entry&.mode == 0o160000
            nested = submodule_repository(absolute)
            raise Error, "Git submodule is not initialized: #{path}" unless nested
            oid = nested.head
            raise Error, "Git submodule has no HEAD: #{path}" unless oid
            index.stage(path, oid, 0o160000, stat: stat)
          else
            content = repository.worktree_content(path)
            mode = stat.symlink? ? 0o120000 : stat.executable? ? 0o100755 : 0o100644
            index.stage(path, repository.write_blob(content), mode, stat: stat)
          end
        else
          index.remove(path)
        end
        index.write
      end
      refresh_after_index_write
      path
    rescue Thuban::RefLockError
      refresh_after_index_write
      raise
    end

    def unstage_git_file(path = nil)
      path ||= selected_scm_path(:staged)
      state = git_state
      raise Error, "Not a Git repository" unless state

      state.synchronize do |repository|
        index = repository.index
        if (entry = repository.tree[path])
          index.stage(path, entry.oid, entry.mode)
        else
          index.remove(path)
        end
        index.write
      end
      refresh_after_index_write
      path
    rescue Thuban::RefLockError
      refresh_after_index_write
      raise
    end

    def show_scm_diff(change = @scm_selection)
      raise Error, "Select a changed file" unless change.is_a?(Hash) && SCM_SECTIONS.key?(change[:kind])

      path, kind = change.values_at(:path, :kind)
      state = git_state
      raise Error, "Not a Git repository" unless state
      before, after = state.synchronize do |repository|
        head = repository.tree[path]
        staged = repository.index[path]
        if head&.mode == 0o160000 || staged&.mode == 0o160000
          gitlink_diff(repository, path, kind, head, staged)
        else
          case kind
          when :staged
            [repository.blob(path), repository.staged_blob(path)]
          when :unstaged
            [repository.staged_blob(path), repository.worktree_content(path)]
          else
            [nil, repository.worktree_content(path)]
          end
        end
      end
      text = begin
        old_text = Buffer.decode_bytes(before.to_s).first
        new_text = Buffer.decode_bytes(after.to_s).first
        Porrima.unified(old_text, new_text, old_name: "a/#{path}", new_name: "b/#{path}")
      rescue EncodingError, Error
        "Binary file changed: #{path}\n"
      end
      buffer = Buffer.new(text, read_only: true)
      @buffers[buffer.object_id] = buffer
      document = @active_pane.open(buffer)
      document.language = Language::Definition.new("diff", "diff", [], "", /\A\z/, /\A\z/, [])
      invalidate_hidden_selection_ranges
      document
    end

    private

    def gitlink_diff(repository, path, kind, head, staged)
      case kind
      when :staged
        [gitlink_entry_text(head), gitlink_entry_text(staged)]
      when :unstaged
        [gitlink_entry_text(staged), gitlink_worktree_text(repository, path)]
      else
        ["", gitlink_worktree_text(repository, path)]
      end
    end

    def gitlink_entry_text(entry)
      return "" unless entry
      return "Subproject commit #{entry.oid}\n" if entry.mode == 0o160000

      "Git object #{entry.oid} (mode #{entry.mode.to_s(8)})\n"
    end

    def gitlink_worktree_text(repository, path)
      absolute = repository.worktree_path(path)
      return "" unless File.exist?(absolute) || File.symlink?(absolute)
      return "Submodule path is not a directory\n" unless File.directory?(absolute) && !File.symlink?(absolute)

      nested = submodule_repository(absolute)
      return "Submodule is not initialized\n" unless nested
      oid = nested.head
      oid ? "Subproject commit #{oid}\n" : "Submodule has no HEAD\n"
    rescue ArgumentError, Thuban::CorruptObject, SystemCallError
      "Submodule is unavailable\n"
    end

    def submodule_repository(absolute)
      nested = Thuban::Repository.new(absolute)
      return unless nested.root && File.realpath(nested.root) == File.realpath(absolute)

      nested
    rescue ArgumentError, SystemCallError
      nil
    end

    def scm_nodes(entries = git_status)
      grouped = SCM_SECTIONS.to_h { |kind, _| [kind, []] }
      entries.sort.each do |path, code|
        change = ->(kind) { {path: path, kind: kind, code: code}.freeze }
        grouped[:untracked] << scm_file_node(change.call(:untracked)) if code == "??"
        grouped[:staged] << scm_file_node(change.call(:staged)) if code.getbyte(0) != 32 && code.getbyte(0) != 63
        grouped[:unstaged] << scm_file_node(change.call(:unstaged)) if code.getbyte(1) != 32 && code.getbyte(1) != 63
      end
      SCM_SECTIONS.map do |kind, label|
        children = grouped.fetch(kind).freeze
        {id: [:scm_section, kind].freeze, label: "#{label} (#{children.length})".freeze,
         value: nil, children: children}.freeze
      end.freeze
    end

    def scm_file_node(change)
      path, kind, code = change.values_at(:path, :kind, :code)
      mark = kind == :untracked ? "?" : kind == :staged ? code[0] : code[1]
      {id: [:scm_file, kind, path].freeze, label: "#{mark} #{path}".freeze, value: change}.freeze
    end

    def select_scm_change(change, event = nil)
      return false unless change.is_a?(Hash) && SCM_SECTIONS.key?(change[:kind])

      @scm_selection = change
      if event&.click_count.to_i >= 2
        change[:kind] == :staged ? unstage_git_file(change[:path]) : stage_git_file(change[:path])
      else
        show_scm_diff(change)
      end
      true
    end

    def selected_scm_path(*kinds)
      change = @scm_selection
      raise Error, "Select a #{kinds == [:staged] ? 'staged' : 'changed'} file" unless change.is_a?(Hash) && kinds.include?(change[:kind])
      change.fetch(:path)
    end

    def refresh_after_index_write
      invalidate_git
      refresh_scm
    end
  end
end
