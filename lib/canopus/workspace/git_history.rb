# frozen_string_literal: true

module Canopus
  module Workspace::GitHistory
    MAX_COMMITS = 200
    MAX_HISTORY_TREE_ENTRIES = 200_000
    MAX_COMMIT_PATHS = 2_000

    GitCommitEntry = Data.define(:oid, :parents, :subject, :author, :time, :paths, :graph, :paths_truncated)

    def git_commit_history(revision: "HEAD", limit: 100)
      state = git_state
      raise Error, "Not a Git repository" unless state
      revision = validate_git_revision(revision)
      unless limit.is_a?(Integer) && limit.between?(1, MAX_COMMITS)
        raise ArgumentError, "history limit must be between 1 and #{MAX_COMMITS}"
      end

      state.synchronize { |repository| collect_git_commit_history(repository, revision, limit) }
    end

    def show_git_commit_history(revision: "HEAD", limit: 100, async: !!@window)
      revision = validate_git_revision(revision)
      if @window && async
        generation = @git_commit_history_generation = (@git_commit_history_generation || 0) + 1
        palette_generation = @palette_generation.to_i
        self.message = "Loading Git history…"
        worker = Thread.new do
          current = Thread.current
          entries = git_commit_history(revision: revision, limit: limit)
          post { finish_git_commit_history(current, generation, palette_generation, entries, nil) } unless @closed
        rescue StandardError => error
          post { finish_git_commit_history(current, generation, palette_generation, nil, error) } unless @closed
        end
        (@git_commit_history_jobs ||= []) << worker
        return worker
      end

      install_git_commit_history(git_commit_history(revision: revision, limit: limit))
    end

    def open_git_commit(entry)
      raise ArgumentError, "expected a Git commit entry" unless entry.is_a?(GitCommitEntry)
      if entry.paths.empty?
        self.message = entry.paths_truncated ? "Changed paths omitted by the history budget" : "Commit has no file changes"
        return
      end
      return compare_git_revisions(entry.parents.first, entry.oid, path: entry.paths.first) if entry.paths.one?

      labels = entry.paths.map { |path| scm_display_path(path) }
      self.palette = {kind: :git_commit_paths, query: +"", index: 0, matches: labels,
        all_matches: labels, items: entry.paths, commit: entry}
      update_palette
      @palette
    end

    def close_git
      @git_commit_history_generation = (@git_commit_history_generation || 0) + 1
      jobs = [*@git_commit_history_jobs].compact.uniq.reject { |thread| thread.equal?(Thread.current) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.1
      jobs.each do |thread|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?
        thread.join(remaining)
      end
      jobs.each { |thread| thread.kill if thread.alive? }
      jobs.each(&:join)
      @git_commit_history_jobs&.clear
      super
    end

    private

    def collect_git_commit_history(repository, revision, limit)
      resolve_git_revision(repository, revision)
      lanes = []
      tree_entries = 0
      commits = topological_git_commits(repository.each_commit(revision, limit: limit).to_a)
      commits.map do |commit|
        parents = commit.parents.map { |oid| oid.dup.freeze }.freeze
        lane = lanes.index(commit.oid) || lanes.length
        lanes << commit.oid unless lanes.include?(commit.oid)
        graph = lanes.each_index.map { |index| index == lane ? "●" : "│" }.join(" ").freeze
        lanes.delete_at(lane)
        parents.reverse_each { |parent| lanes.insert(lane, parent) unless lanes.include?(parent) }

        paths, consumed, truncated = git_commit_paths(repository, commit, MAX_HISTORY_TREE_ENTRIES - tree_entries)
        tree_entries += consumed
        signature = commit.signature(role: :author)
        GitCommitEntry.new(commit.oid.dup.freeze, parents,
          safe_git_history_text(commit.message.to_s.lines.first, 200).freeze,
          safe_git_history_text(signature.name, 100).freeze, signature.time,
          paths.freeze, graph, truncated).freeze
      end.freeze
    end

    def topological_git_commits(commits)
      remaining = commits.dup
      ordered = []
      until remaining.empty?
        index = remaining.index do |candidate|
          remaining.none? { |child| child.parents.include?(candidate.oid) }
        end
        raise Error, "Invalid Git commit graph" unless index

        ordered << remaining.delete_at(index)
      end
      ordered
    end

    def git_commit_paths(repository, commit, remaining)
      return [[], 0, true] unless remaining.positive?

      current = repository.tree(commit.oid)
      previous = commit.parents.first ? repository.tree(commit.parents.first) : {}
      paths, consumed, truncated = [], 0, false
      current.each do |path, entry|
        consumed += 1
        if consumed > remaining
          truncated = true
          break
        end
        paths << path.dup.freeze unless same_git_tree_entry?(entry, previous[path])
        if paths.length >= MAX_COMMIT_PATHS
          truncated = true
          break
        end
      end
      unless truncated
        previous.each do |path, entry|
          consumed += 1
          if consumed > remaining
            truncated = true
            break
          end
          paths << path.dup.freeze unless current.key?(path) || same_git_tree_entry?(current[path], entry)
          if paths.length >= MAX_COMMIT_PATHS
            truncated = true
            break
          end
        end
      end
      [paths.sort_by(&:b), [consumed, remaining].min, truncated]
    end

    def git_commit_history_label(entry)
      paths = entry.paths.first(4).map { |path| scm_display_path(path) }.join(", ")
      paths << ", …" if entry.paths.length > 4 || entry.paths_truncated
      suffix = paths.empty? ? "" : " · #{paths}"
      "#{entry.graph} #{entry.oid[0, 8]} #{entry.subject} · #{entry.author}#{suffix}"
    end

    def git_commit_history_search(entry)
      ([entry.oid, entry.subject, entry.author] + entry.paths.map { |path| scm_display_path(path) }).join(" ")
    end

    def install_git_commit_history(entries)
      self.palette = {kind: :git_commit_history, query: +"", index: 0,
        matches: entries.map { |entry| git_commit_history_label(entry) }, items: entries,
        search_values: entries.map { |entry| git_commit_history_search(entry) }}
      update_palette
      @palette
    end

    def finish_git_commit_history(worker, generation, palette_generation, entries, error)
      @git_commit_history_jobs&.delete(worker)
      return unless generation == @git_commit_history_generation && palette_generation == @palette_generation.to_i
      error ? self.message = "Git history: #{safe_git_history_text(error.message, 500)}" : install_git_commit_history(entries)
    end
  end
end
