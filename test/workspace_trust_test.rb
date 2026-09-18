# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class WorkspaceTrustTest < Minitest::Test
  def test_trust_state_is_hashed_and_atomic
    Dir.mktmpdir("canopus-trust-") do |root|
      state = File.join(root, "state", "trust.json")
      trust = Canopus::Workspace::Trust.new(root, state_path: state)
      refute trust.trusted?
      assert_equal :trusted, trust.trust! && trust.status
      assert File.file?(state)
      assert_equal 0o600, File.stat(state).mode & 0o777
      refute_includes File.read(state), root
      assert Canopus::Workspace::Trust.new(root, state_path: state).trusted?
      refute Canopus::Workspace::Trust.new(root, state_path: state).untrust!
      assert_equal :untrusted, Canopus::Workspace::Trust.new(root, state_path: state).status
    end
  end

  def test_workspace_exposes_stage_one_trust_commands_without_restricting_execution
    Dir.mktmpdir("canopus-trust-workspace-") do |root|
      workspace = Canopus::Workspace.new(root: root)
      assert_equal :untrusted, workspace.show_workspace_trust
      assert_equal :trusted, workspace.toggle_workspace_trust
      assert workspace.trust.trusted?
      assert_equal :untrusted, workspace.toggle_workspace_trust
    ensure
      workspace&.close
    end
  end
end
