# frozen_string_literal: true

require_relative "test_helper"

class GitStateTest < Minitest::Test
  Entry = Struct.new(:path, :index, :worktree) do
    def code = index + worktree
  end

  class Repository
    attr_reader :root, :git_dir, :calls
    attr_accessor :head_value, :branch_value, :entries, :before

    def initialize(root)
      @root, @git_dir = root, File.join(root, ".git")
      @head_value, @branch_value = "head-one", "main"
      @entries = [Entry.new(+"example.rb", "M", " ")]
      @before = "before\n"
      @calls = Queue.new
    end

    def head
      @calls << [:head, Thread.current]
      wait_at(@head_gate)
      @head_value
    end

    def branch = @branch_value

    def status
      @calls << [:status, Thread.current]
      wait_at(@status_gate)
      @entries.map(&:dup)
    end

    def blob(*)
      @calls << [:blob, Thread.current]
      @before.dup
    end

    def block_next(operation)
      gate = [Queue.new, Queue.new]
      instance_variable_set(:"@#{operation}_gate", gate)
      gate
    end

    private

    def wait_at(gate)
      return unless gate

      gate.first << true
      gate.last.pop
      @head_gate = @status_gate = nil if @head_gate.equal?(gate) || @status_gate.equal?(gate)
    end
  end

  class Window
    attr_reader :frames
    def initialize = @frames = 0
    def request_frame = @frames += 1
  end

  def setup
    @directory = Dir.mktmpdir("canopus-git-state-")
    FileUtils.mkdir_p(File.join(@directory, ".git"))
    File.binwrite(File.join(@directory, ".git", "index"), "index-one")
    File.binwrite(File.join(@directory, "example.rb"), "after\n")
    @workspace = Canopus::Workspace.new(root: @directory)
    @repository = Repository.new(@workspace.root)
    @workspace.instance_variable_set(:@git, @repository)
    @workspace.window = Window.new
    @editor = @workspace.open("example.rb")
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@directory)
  end

  def test_status_is_published_as_one_immutable_background_snapshot
    started, release = @repository.block_next(:status)
    assert_equal({}, @workspace.git_status)
    wait_until { !started.empty? }
    assert_nil git_state.snapshot
    release << true
    wait_until { @workspace.git_status["example.rb"] == "M " }

    snapshot = git_state.snapshot
    call = drain_calls.find { |name, _| name == :status }
    refute_equal Thread.current, call.last
    assert_equal ["head-one", "main"], [snapshot.head, snapshot.branch]
    assert_equal 4, snapshot.index_stamp.length
    assert snapshot.frozen?
    assert snapshot.index_stamp.frozen?
    assert snapshot.entries.frozen?
    assert snapshot.entries.keys.first.frozen?
    assert snapshot.entries.values.first.frozen?
    @repository.entries.first.path.replace("changed.rb")
    assert_equal({"example.rb" => "M "}, snapshot.entries)
  end

  def test_capture_retries_when_the_index_changes_during_status
    original = @repository.method(:status)
    changed = false
    @repository.define_singleton_method(:status) do
      entries = original.call
      unless changed
        changed = true
        @entries = [Entry.new("hidden.rb", "M", " ")]
        File.binwrite(File.join(@git_dir, "index"), "index-two-longer")
      end
      entries
    end

    snapshot = Canopus::Git::State.new(@repository).capture

    assert_equal({"hidden.rb" => "M "}, snapshot.entries)
    assert_equal File.stat(File.join(@directory, ".git", "index")).size, snapshot.index_stamp[2]
  end

  def test_poll_reads_repository_state_in_background_and_refreshes_the_snapshot
    @workspace.git_status
    wait_until { @workspace.git_status["example.rb"] }
    original = git_state.snapshot
    @repository.head_value = "head-two"
    @repository.branch_value = "topic"
    @repository.entries = [Entry.new("example.rb", " ", "M")]
    File.binwrite(File.join(@directory, ".git", "index"), "index-two-longer")
    started, release = @repository.block_next(:head)

    assert_nil @workspace.poll_git_changes(now: 10)
    wait_until { !started.empty? }
    assert_same original, git_state.snapshot
    release << true
    wait_until { git_state.snapshot.nil? }
    assert_equal({}, @workspace.git_status)
    wait_until { @workspace.git_status["example.rb"] == " M" }
    assert_equal ["head-two", "topic"], [git_state.snapshot.head, git_state.snapshot.branch]
    refute_equal original.index_stamp, git_state.snapshot.index_stamp
  end

  def test_close_joins_status_and_diff_workers_sharing_the_repository_mutex
    started, release = @repository.block_next(:status)
    @workspace.git_status
    wait_until { !started.empty? }
    assert_nil @workspace.git_diff(@editor.buffer)
    status = @workspace.instance_variable_get(:@git_status_job)
    diff = @workspace.instance_variable_get(:@git_diff_jobs).fetch(@editor.buffer)
    closer = Thread.new { @workspace.close }
    refute closer.join(0.05), "close returned before the Git worker finished"
    assert_empty drain_calls.select { |name, _| name == :blob }

    release << true
    assert closer.join(3), "workspace close did not join Git workers"
    closer.value
    refute_predicate status, :alive?
    refute_predicate diff, :alive?
    @workspace = nil
  end

  private

  def git_state = @workspace.instance_variable_get(:@git_state)

  def drain_calls
    calls = []
    calls << @repository.calls.pop(true) until @repository.calls.empty?
    calls
  end

  def wait_until(timeout = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      @workspace.drain
      raise "Git state timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
    @workspace.drain
  end
end
