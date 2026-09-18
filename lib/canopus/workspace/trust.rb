# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tempfile"

module Canopus
  class Workspace::Trust
    def initialize(root, state_path: nil)
      @root = File.realpath(root)
      @state_path = state_path || File.join(ENV["XDG_STATE_HOME"] || File.expand_path("~/.local/state"), "canopus", "trust.json")
      @key = Digest::SHA256.hexdigest(@root)
      @states = load_states
    end

    def trusted? = @states[@key] == true
    def status = trusted? ? :trusted : :untrusted

    def trust!
      update(true)
    end

    def untrust!
      update(false)
    end

    private

    def update(value)
      @states[@key] = value
      FileUtils.mkdir_p(File.dirname(@state_path))
      Tempfile.create([".trust-", ".json"], File.dirname(@state_path), perm: 0o600) do |file|
        file.write(JSON.generate(@states))
        file.flush
        file.fsync
        file.close
        File.chmod(0o600, file.path)
        File.rename(file.path, @state_path)
      end
      value
    end

    def load_states
      value = JSON.parse(File.read(@state_path))
      value.is_a?(Hash) ? value.select { |key, state| key.is_a?(String) && (state.is_a?(TrueClass) || state.is_a?(FalseClass)) } : {}
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, TypeError
      {}
    end
  end

  module Workspace::TrustAware
    def workspace_trust = @trust

    def toggle_workspace_trust
      if @trust.trusted?
        @trust.untrust!
        @message = "Workspace untrusted"
      else
        @trust.trust!
        @message = "Workspace trusted"
      end
      @window&.request_frame
      @trust.status
    end

    def show_workspace_trust
      @message = "Workspace #{@trust.status}"
      @window&.request_frame
      @trust.status
    end
  end
end
