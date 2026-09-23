# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class GitRemoteTest < Minitest::Test
  class Repository
    attr_reader :root, :git_dir, :calls, :started
    attr_accessor :mode, :failure

    def initialize(root)
      @root, @git_dir = root, File.join(root, ".git")
      @calls, @started = Queue.new, Queue.new
      @mode = :success
    end

    def remotes = {"origin" => "https://private.example.invalid/repository.git"}
    def branch = "main"
    def head = "a" * 40

    def fetch(remote, credentials:, cancelled:, &progress)
      transfer(:fetch, remote, credentials, cancelled, progress)
    end

    def pull(remote, credentials:, cancelled:, &progress)
      transfer(:pull, remote, credentials, cancelled, progress)
    end

    def push(remote, refspecs:, credentials:, cancelled:, &progress)
      @calls << [:refspec, refspecs]
      transfer(:push, remote, credentials, cancelled, progress)
    end

    private

    def transfer(operation, remote, credentials, cancelled, progress)
      @calls << [operation, remote, credentials]
      raise Thuban::AuthenticationError, "remote authentication required" if @mode == :auth
      raise @failure if @mode == :error
      return true unless @mode == :block

      progress.call(Thuban::Progress.new(phase: :pack, current: 1, total: 3, bytes: 99))
      @started << true
      sleep 0.005 until cancelled.call
      raise Thuban::Cancelled, "transfer cancelled"
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-git-remote-")
    FileUtils.mkdir_p(File.join(@root, ".git"))
    File.binwrite(File.join(@root, "example.txt"), "base\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @repository = Repository.new(@root)
    @workspace.instance_variable_set(:@git, @repository)
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root)
  end

  def test_transfer_is_single_background_job_with_bounded_progress_and_cancellation
    @repository.mode = :block
    worker = @workspace.fetch_git
    @repository.started.pop
    wait_until { @workspace.git_transfer_progress }

    progress = @workspace.git_transfer_progress
    assert_equal({operation: :fetch, remote: "origin", phase: :pack, current: 1, total: 3, bytes: 99}, progress)
    refute_includes progress.values.join, "private.example.invalid"
    assert_raises(Canopus::Error) { @workspace.push_git }
    assert @workspace.cancel_git_transfer
    assert worker.join(3), "cancelled transfer did not stop"
    wait_until { @workspace.message == "Git fetch cancelled" }
  end

  def test_pull_rejects_dirty_buffers_and_locks_clean_buffers_during_transfer
    editor = @workspace.open("example.txt")
    editor.insert_text("dirty")
    assert_raises(Canopus::Error) { @workspace.pull_git }
    editor.undo

    @repository.mode = :block
    worker = @workspace.pull_git
    @repository.started.pop
    assert_raises(Canopus::Error) { editor.insert_text("blocked") }
    @workspace.cancel_git_transfer
    worker.join
    wait_until { !editor.buffer.read_only }
  end

  def test_helper_fallback_masks_and_redacts_temporary_credentials
    helper = Object.new
    @repository.mode = :auth
    Thuban::Remote::Credentials.stub(:helper, helper) do
      worker = @workspace.fetch_git
      worker.join
      wait_until { @workspace.palette&.dig(:kind) == :git_credentials }
    end
    assert_same helper, @repository.calls.pop[2]

    @workspace.palette[:query].clear
    password = @workspace.accept_git_credentials
    assert_equal :token, password[:stage]
    password[:query].replace("top-secret-token")
    view = Canopus::Workspace::View.new(@workspace)
    masked = view.send(:palette_query_text, password)
    refute_includes masked, "top-secret-token"
    assert_match(/\A•+\z/, masked)

    @repository.mode = :error
    @repository.failure = RuntimeError.new("server echoed top-secret-token")
    worker = @workspace.accept_git_credentials
    worker.join
    wait_until { @workspace.git_transfer_progress.nil? }
    refute_includes @workspace.message, "top-secret-token"
    assert_includes @workspace.message, "[REDACTED]"
    refute_includes @workspace.palette.to_s, "top-secret-token"
  end

  def test_autofetch_waits_for_the_configured_interval
    calls = []
    @workspace.define_singleton_method(:fetch_git) { calls << true }

    @workspace.poll_git_changes(now: 1)
    assert_empty calls
    @workspace.settings.merge!("git" => {"autofetch" => true, "autofetch_interval" => 180})
    @workspace.poll_git_changes(now: 10)
    @workspace.poll_git_changes(now: 189)
    assert_empty calls
    @workspace.poll_git_changes(now: 190)
    assert_equal 1, calls.length
    @workspace.poll_git_changes(now: 369)
    assert_equal 1, calls.length
    @workspace.poll_git_changes(now: 370)
    assert_equal 2, calls.length
  end

  def test_close_cancels_and_joins_the_transfer
    @repository.mode = :block
    @workspace.settings.merge!("git" => {"autofetch" => true, "autofetch_interval" => 10})
    @workspace.poll_git_changes(now: 0)
    @workspace.poll_git_changes(now: 10)
    @repository.started.pop
    worker = @workspace.instance_variable_get(:@git_transfer_state).job
    @workspace.poll_git_changes(now: 20)
    assert_equal 1, @repository.calls.size

    @workspace.close

    refute_predicate worker, :alive?
    assert_nil @workspace.poll_git_changes(now: 30)
    assert_equal 1, @repository.calls.size
    @workspace = nil
  end

  private

  def wait_until(timeout = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      @workspace.drain
      return if yield
      raise "Git remote timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end
end

class GitRemoteIntegrationTest < Minitest::Test
  def setup
    @base = Dir.mktmpdir("canopus-git-remote-integration-")
    @root, @origin, @peer = %w[work origin.git peer].map { |name| File.join(@base, name) }
    git(nil, "init", "-q", "--bare", @origin)
    git(nil, "init", "-q", "-b", "main", @root)
    configure(@root)
    File.binwrite(File.join(@root, "example.txt"), "base\n")
    git(@root, "add", ".")
    git(@root, "commit", "-qm", "Initial")
    git(@root, "remote", "add", "origin", @origin)
    git(@root, "push", "-qu", "origin", "main")
    git(nil, "-c", "core.autocrlf=false", "clone", "-q", "-b", "main", @origin, @peer)
    configure(@peer)
    @workspace = Canopus::Workspace.new(root: @root)
    @editor = @workspace.open("example.txt")
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@base)
  end

  def test_pull_reloads_clean_buffers_and_push_interoperates_with_git
    File.binwrite(File.join(@peer, "example.txt"), "from peer\n")
    git(@peer, "add", ".")
    git(@peer, "commit", "-qm", "Peer update")
    git(@peer, "push", "-q", "origin", "main")

    transfer = @workspace.pull_git
    assert transfer.join(30), "local pull timed out"
    wait_until { @workspace.message == "Git pull complete" }
    assert_equal "from peer\n", @editor.buffer.text

    File.binwrite(File.join(@root, "example.txt"), "from work\n")
    @editor.buffer.reload
    git(@root, "add", ".")
    git(@root, "commit", "-qm", "Work update")
    transfer = @workspace.push_git
    assert transfer.join(30), "local push timed out"
    wait_until { @workspace.message == "Git push complete" }
    git(@peer, "pull", "-q", "--ff-only")
    assert_equal "from work\n", File.read(File.join(@peer, "example.txt"))
  end

  private

  def configure(directory)
    git(directory, "config", "user.name", "Remote Test")
    git(directory, "config", "user.email", "remote@example.invalid")
    git(directory, "config", "core.autocrlf", "false")
  end

  def git(directory, *arguments)
    command = ["git"]
    command += ["-C", directory] if directory
    output, error, status = Open3.capture3(*command, *arguments)
    raise "git #{arguments.join(' ')}: #{error}" unless status.success?
    output
  end

  def wait_until(timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      @workspace.drain
      return if yield
      raise "Git integration timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end
end
