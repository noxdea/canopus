# frozen_string_literal: true

module Canopus
  module Workspace::GitRemote
    TRANSFER_PHASES = %i[pack remote push].freeze
    GitTransferState = Struct.new(:operation, :remote, :lock, :cancelled, :job, :progress,
      :progress_posted, :prompt_auth, :redactions, :locked_buffers, keyword_init: true) do
      def cancel!
        lock.synchronize { self.cancelled = true }
      end

      def cancelled? = lock.synchronize { cancelled }
    end
    private_constant :GitTransferState

    def git_remotes
      state = git_state
      raise Error, "Not a Git repository" unless state
      state.synchronize { |repository| repository.remotes.transform_keys { |name| name.dup.freeze }.freeze }
    end

    def fetch_git(remote = nil, credentials: nil)
      start_git_transfer(:fetch, remote, credentials: credentials)
    end

    def pull_git(remote = nil, credentials: nil)
      raise Error, "Save or discard all buffer changes before pulling" if @buffers.values.any?(&:dirty?)
      start_git_transfer(:pull, remote, credentials: credentials)
    end

    def push_git(remote = nil, credentials: nil)
      start_git_transfer(:push, remote, credentials: credentials)
    end

    def cancel_git_transfer
      state = (@git_transfer_guard ||= Mutex.new).synchronize { @git_transfer_state }
      return false unless state

      state.cancel!
      self.message = "Cancelling Git #{state.operation}…"
      true
    end

    def git_transfer_progress
      state = (@git_transfer_guard ||= Mutex.new).synchronize { @git_transfer_state }
      state&.lock&.synchronize { state.progress }
    end

    def poll_git_changes(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      return if @closed

      super
      poll_git_autofetch(now)
      nil
    end

    def accept_git_credentials
      prompt = @palette
      raise Error, "No Git credential prompt is open" unless prompt&.dig(:kind) == :git_credentials

      value = prompt.fetch(:query)
      if prompt[:stage] == :username
        raise Error, "Git username is too long" if value.bytesize > 1_024
        username = value.dup
        value.clear
        self.palette = prompt.merge(stage: username.empty? ? :token : :password, username: username,
          query: +"", secret: true, matches: [])
        return @palette
      end

      raise Error, "Git credential is too long" if value.bytesize > 4_096
      secret = value.dup
      value.clear
      operation, remote, username = prompt.values_at(:operation, :remote, :username)
      self.palette = nil
      credentials = username.to_s.empty? ? Thuban::Remote::Credentials.bearer(token: secret) :
        Thuban::Remote::Credentials.static(username: username, password: secret)
      start_git_transfer(operation, remote, credentials: credentials, prompt_auth: false,
        redactions: [username, secret].compact)
    ensure
      secret&.clear
    end

    def close_git
      state = (@git_transfer_guard ||= Mutex.new).synchronize { @git_transfer_state }
      if state
        state.cancel!
        state.job&.join unless state.job&.equal?(Thread.current)
      end
      super
    end

    private

    def poll_git_autofetch(now)
      options = @settings["git"]
      return unless options["autofetch"]
      unless @last_git_autofetch
        @last_git_autofetch = now
        return
      end
      return if now - @last_git_autofetch < options["autofetch_interval"]
      return if (@git_transfer_guard ||= Mutex.new).synchronize { @git_transfer_state }

      @last_git_autofetch = now
      fetch_git
    rescue Error => error
      self.message = "Git autofetch: #{safe_git_history_text(error.message, 200)}"
    end

    def start_git_transfer(operation, remote, credentials:, prompt_auth: true, redactions: [])
      if operation == :pull && @buffers.values.any?(&:dirty?)
        raise Error, "Save or discard all buffer changes before pulling"
      end
      state = nil
      guard = @git_transfer_guard ||= Mutex.new
      guard.synchronize do
        raise Error, "A Git transfer is already in progress" if @git_transfer_state
        remote = select_git_remote(operation, remote)
        return remote if remote.is_a?(Hash)
        state = GitTransferState.new(operation: operation, remote: remote, lock: Mutex.new,
          cancelled: false, prompt_auth: prompt_auth && credentials.nil?, redactions: redactions.map(&:dup).freeze,
          locked_buffers: operation == :pull ? lock_pull_buffers : [].freeze)
        @git_transfer_state = state
        state.job = Thread.new { run_git_transfer(state, credentials) }
      end
      self.message = "Git #{operation} started"
      state.job
    rescue StandardError
      unlock_pull_buffers(state&.locked_buffers)
      raise
    end

    def select_git_remote(operation, requested)
      remotes = git_remotes
      if requested
        raise Error, "Unknown Git remote" unless requested.is_a?(String) && remotes.key?(requested)
        return requested.dup.freeze
      end
      return "origin".freeze if remotes.key?("origin")
      return remotes.keys.first if remotes.one?
      raise Error, "No Git remotes are configured" if remotes.empty?

      labels = remotes.keys.map { |name| safe_git_history_text(name, 200) }
      self.palette = {kind: :git_remotes, operation: operation, query: +"", index: 0,
        matches: labels, all_matches: labels, items: remotes.keys}
      update_palette
      @palette
    end

    def run_git_transfer(state, credentials)
      effective = credentials || default_git_credentials(state.remote)
      state.lock.synchronize { state.prompt_auth = false unless effective }
      git_state.synchronize do |repository|
        progress = ->(event) { publish_git_transfer_progress(state, event) }
        cancelled = -> { state.cancelled? }
        case state.operation
        when :fetch
          repository.fetch(state.remote, credentials: effective, cancelled: cancelled, &progress)
        when :pull
          repository.pull(state.remote, credentials: effective, cancelled: cancelled, &progress)
        when :push
          branch = repository.branch
          raise Error, "Cannot push from a detached HEAD" unless branch
          ref = "refs/heads/#{branch}"
          repository.push(state.remote, refspecs: "#{ref}:#{ref}", credentials: effective,
            cancelled: cancelled, &progress)
        end
      end
      post { finish_git_transfer(state, nil) } unless @closed
    rescue StandardError => error
      post { finish_git_transfer(state, error) } unless @closed
    ensure
      (@git_transfer_guard ||= Mutex.new).synchronize do
        @git_transfer_state = nil if @closed && @git_transfer_state.equal?(state)
      end
    end

    def default_git_credentials(remote)
      url = git_remotes[remote]
      url&.match?(/\Ahttps?:\/\//i) ? Thuban::Remote::Credentials.helper : nil
    end

    def publish_git_transfer_progress(state, event)
      phase = TRANSFER_PHASES.include?(event.phase) ? event.phase : :remote
      progress = {operation: state.operation, remote: safe_git_history_text(state.remote, 200), phase: phase,
        current: transfer_number(event.current), total: transfer_number(event.total), bytes: transfer_number(event.bytes)}.freeze
      should_post = state.lock.synchronize do
        state.progress = progress
        next false if state.progress_posted
        state.progress_posted = true
      end
      post { install_git_transfer_progress(state) } if should_post && !@closed
    end

    def transfer_number(value)
      value.is_a?(Integer) && value >= 0 ? value : nil
    end

    def install_git_transfer_progress(state)
      progress = state.lock.synchronize do
        state.progress_posted = false
        state.progress
      end
      return unless (@git_transfer_guard ||= Mutex.new).synchronize { @git_transfer_state.equal?(state) }

      detail = progress[:total] ? " #{progress[:current] || 0}/#{progress[:total]}" :
        progress[:bytes] ? " #{progress[:bytes]} bytes" : ""
      self.message = "Git #{state.operation}: #{progress[:phase]}#{detail}"
    end

    def finish_git_transfer(state, error)
      current = (@git_transfer_guard ||= Mutex.new).synchronize do
        next false unless @git_transfer_state.equal?(state)
        @git_transfer_state = nil
        true
      end
      return unless current

      unlock_pull_buffers(state.locked_buffers)
      if error.is_a?(Thuban::AuthenticationError) && state.prompt_auth
        return prompt_git_credentials(state.operation, state.remote)
      end
      if error
        self.message = git_transfer_error_message(state, error)
        return
      end

      invalidate_git
      refresh_files
      refresh_scm if @scm_tree
      if state.operation == :pull
        @buffers.values.uniq.each do |buffer|
          buffer.reload if buffer.path && File.file?(buffer.path) && !buffer.read_only && !buffer.dirty?
        end
      end
      self.message = "Git #{state.operation} complete"
    end

    def prompt_git_credentials(operation, remote)
      self.palette = {kind: :git_credentials, operation: operation, remote: remote,
        stage: :username, query: +"", index: 0, matches: [], secret: false}
      self.message = "Authentication required; enter a username, or leave blank for a bearer token"
      @palette
    end

    def git_transfer_error_message(state, error)
      return "Git #{state.operation} cancelled" if error.is_a?(Thuban::Cancelled)
      return "Git #{state.operation} authentication failed" if error.is_a?(Thuban::AuthenticationError)
      return "Git #{state.operation} failed" if error.is_a?(Thuban::TransportError)

      text = safe_git_history_text(error.message, 500)
      state.redactions.each { |secret| text = text.gsub(secret, "[REDACTED]") unless secret.empty? }
      "Git #{state.operation}: #{text}"
    end

    def lock_pull_buffers
      buffers = @buffers.values.uniq.select { |buffer| buffer.path && !buffer.read_only }
      buffers.each { |buffer| buffer.instance_variable_set(:@read_only, true) }
      buffers.freeze
    end

    def unlock_pull_buffers(buffers)
      buffers&.each { |buffer| buffer.instance_variable_set(:@read_only, false) }
    end
  end
end
