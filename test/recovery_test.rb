# frozen_string_literal: true

require_relative "test_helper"
require "canopus/cli"
require "stringio"
require "tmpdir"

class RecoveryTest < Minitest::Test
  SizedRope = Struct.new(:bytesize)
  SizedBuffer = Struct.new(:rope, :version, :path) do
    def dirty? = true
    def close = nil
  end

  def setup
    @root = Dir.mktmpdir("canopus-recovery-")
    @workspaces = []
  end

  def teardown
    @workspaces.each { |workspace| workspace.close rescue nil }
    FileUtils.remove_entry(@root)
  end

  def workspace(settings = Canopus::Settings.new)
    Canopus::Workspace.new(root: @root, settings: settings).tap { |created| @workspaces << created }
  end

  def leave_recovery_snapshot
    crashed = workspace
    crashed.new_buffer.insert_text("crash draft")
    crashed.poll_recovery(force: true)
    snapshot = Dir.glob(File.join(crashed.recovery_directory, "*.json")).fetch(0)
    crashed.preserve_recovery!
    crashed.close
    @workspaces.delete(crashed)
    snapshot
  end

  def test_abnormal_close_offers_and_restores_paths_and_untitled_buffers
    FileUtils.mkdir_p([File.join(@root, "one"), File.join(@root, "two")])
    File.write(File.join(@root, "one", "same.txt"), "one")
    File.write(File.join(@root, "two", "same.txt"), "two")
    crashed = workspace
    crashed.open("one/same.txt").insert_text("dirty ")
    crashed.open("two/same.txt").insert_text("dirty ")
    crashed.new_buffer.insert_text("untitled")
    assert crashed.poll_recovery(force: true)
    snapshot = Dir.glob(File.join(crashed.recovery_directory, "*.json")).fetch(0)
    unless Gem.win_platform?
      assert_equal 0o600, File.stat(snapshot).mode & 0o777
      assert_equal 0o700, File.stat(crashed.recovery_directory).mode & 0o777
    end
    assert_equal "*\n", File.read(File.join(crashed.recovery_directory, ".gitignore"))
    assert_empty workspace.recovery_candidates, "a live writer must not be offered as crashed"

    crashed.preserve_recovery!
    crashed.close
    @workspaces.delete(crashed)
    restored = workspace
    assert_equal [snapshot], restored.recovery_candidates
    assert restored.offer_recovery
    assert_equal :recovery, restored.palette[:kind]
    assert restored.resolve_recovery(:restore)
    texts = restored.buffers.values.reject { |buffer| buffer.is_a?(Canopus::MultiBuffer) }.map(&:text)
    assert_includes texts, "dirty one"
    assert_includes texts, "dirty two"
    assert_includes texts, "untitled"
    refute File.exist?(snapshot)
  end

  def test_clean_close_removes_only_its_snapshot
    first = workspace
    first.new_buffer.insert_text("first")
    first.poll_recovery(force: true)
    first_snapshot = Dir.glob(File.join(first.recovery_directory, "*.json")).fetch(0)

    second = workspace
    second.new_buffer.insert_text("second")
    second.poll_recovery(force: true)
    snapshots = Dir.glob(File.join(second.recovery_directory, "*.json"))
    assert_equal 2, snapshots.length
    first.close
    @workspaces.delete(first)
    refute File.exist?(first_snapshot)
    refute File.exist?(first_snapshot.sub(/\.json\z/, ".lock"))
    assert_equal 1, Dir.glob(File.join(second.recovery_directory, "*.json")).length
  end

  def test_discarding_recovery_keeps_an_explicitly_restored_session
    crashed = workspace
    crashed.new_buffer.insert_text("crash draft")
    crashed.poll_recovery(force: true)
    crashed.preserve_recovery!
    crashed.close
    @workspaces.delete(crashed)

    saved = workspace
    saved.new_buffer.insert_text("session draft")
    session = File.join(@root, "session.json")
    saved.save_session(session)
    saved.close
    @workspaces.delete(saved)

    current = workspace
    current.restore_session(session)
    assert current.offer_recovery
    assert current.resolve_recovery(:discard)
    assert_equal ["session draft"], current.buffers.values.map(&:text)
  end

  def test_corrupt_foreign_and_oversized_candidates_are_ignored
    current = workspace
    directory = current.recovery_directory
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "bad.json"), "{")
    File.write(File.join(directory, "foreign.json"), JSON.generate(version: 2, root: @root + "-other",
      panes: [], buffers: {"1" => {"draft" => "secret"}}))
    File.open(File.join(directory, "huge.json"), "wb") do |file|
      file.truncate(Canopus::Workspace::Recoverable::MAX_SNAPSHOT_BYTES + 1)
    end
    assert_empty current.recovery_candidates
    refute current.offer_recovery
  end

  def test_symlinked_recovery_paths_and_locks_are_never_followed
    Dir.mktmpdir("canopus-recovery-external-") do |external|
      source = workspace
      source.new_buffer.insert_text("external draft")
      external_recovery = File.join(external, "recovery")
      external_snapshot = File.join(external_recovery, "outside.json")
      source.save_session(external_snapshot)
      source.close
      @workspaces.delete(source)

      canopus = File.join(@root, ".canopus")
      FileUtils.mkdir_p(canopus)
      File.symlink(external_recovery, File.join(canopus, "recovery"))
      current = workspace
      assert_empty current.recovery_candidates
      refute current.offer_recovery
      current.palette = {kind: :recovery, candidate: File.join(current.recovery_directory, "outside.json"),
        query: "Recover?", index: 1, matches: ["Restore", "Discard"]}
      refute current.resolve_recovery(:discard)
      assert File.file?(external_snapshot)

      File.unlink(File.join(canopus, "recovery"))
      Dir.rmdir(canopus)
      external_canopus = File.join(external, "canopus")
      FileUtils.mkdir_p(File.join(external_canopus, "recovery"))
      second_snapshot = File.join(external_canopus, "recovery", "outside.json")
      source = workspace
      source.new_buffer.insert_text("second external draft")
      source.save_session(second_snapshot)
      source.close
      @workspaces.delete(source)
      File.symlink(external_canopus, canopus)

      assert_empty current.recovery_candidates
      refute current.offer_recovery
      current.palette = {kind: :recovery, candidate: File.join(current.recovery_directory, "outside.json"),
        query: "Recover?", index: 0, matches: ["Restore", "Discard"]}
      refute current.resolve_recovery(:restore)
      assert File.file?(second_snapshot)
      File.unlink(canopus)
    end

    snapshot = leave_recovery_snapshot
    lock = snapshot.sub(/\.json\z/, ".lock")
    sentinel = File.join(@root, "outside.lock")
    File.write(sentinel, "do not follow")
    File.delete(lock)
    File.symlink(sentinel, lock)
    current = workspace
    assert_empty current.recovery_candidates
    refute current.offer_recovery
    current.palette = {kind: :recovery, candidate: snapshot, query: "Recover?", index: 1,
      matches: ["Restore", "Discard"]}
    refute current.resolve_recovery(:discard)
    assert File.file?(snapshot)
    assert_equal "do not follow", File.read(sentinel)
  rescue NotImplementedError, Errno::EACCES
    skip "symbolic links are unavailable"
  end

  def test_snapshot_budget_is_checked_conservatively_before_serialization_and_not_retried
    current = workspace
    exact_bytes = (Canopus::Workspace::Recoverable::MAX_SNAPSHOT_BYTES -
      Canopus::Workspace::Recoverable::SNAPSHOT_OVERHEAD_BYTES) / Canopus::Workspace::Recoverable::JSON_ESCAPE_FACTOR
    exact = SizedBuffer.new(SizedRope.new(exact_bytes), 1, nil)
    over = SizedBuffer.new(SizedRope.new(exact_bytes + 1), 1, nil)
    refute current.send(:recovery_snapshot_too_large?, [exact])
    assert current.send(:recovery_snapshot_too_large?, [over])

    current.new_buffer.insert_text("small")
    assert current.poll_recovery(force: true)
    snapshot = Dir.glob(File.join(current.recovery_directory, "*.json")).fetch(0)
    current.buffers[exact.object_id] = exact
    refute current.poll_recovery(force: true)
    refute File.exist?(snapshot)
    calls = 0
    current.define_singleton_method(:ensure_recovery_storage) { calls += 1 }
    later = current.instance_variable_get(:@last_recovery_poll) + 6
    refute current.poll_recovery(now: later)
    assert_equal 0, calls
  end

  def test_recovery_palette_does_not_edit_its_fixed_query_or_matches
    leave_recovery_snapshot
    current = workspace
    window = Zaniah::Platform.open_window(backend: :headless, width: 320, height: 200)
    controller = Canopus::Controller.new(current, window)
    assert_equal :recovery, current.palette[:kind]
    query = current.palette[:query].dup
    matches = current.palette[:matches].dup
    controller.input(Zaniah::Input::KeyDown.new("backspace", false))
    controller.input(Zaniah::Input::TextInput.new("x"))
    assert_equal query, current.palette[:query]
    assert_equal matches, current.palette[:matches]
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_restore_reopens_requested_paths_and_reuses_the_recovered_draft
    recovered_path = File.join(@root, "recovered.rb")
    requested_path = File.join(@root, "requested.rb")
    File.write(recovered_path, "disk recovered\n")
    File.write(requested_path, "disk requested\n")
    recovered_path = File.realpath(recovered_path)
    requested_path = File.realpath(requested_path)
    crashed = workspace
    crashed.open(recovered_path).insert_text("dirty ")
    assert crashed.poll_recovery(force: true)
    crashed.preserve_recovery!
    crashed.close
    @workspaces.delete(crashed)

    current = workspace
    current.open(recovered_path)
    current.open(requested_path)
    window = Zaniah::Platform.open_window(backend: :headless, width: 320, height: 200)
    Canopus::Controller.new(current, window)
    assert_equal :recovery, current.palette[:kind]
    assert current.resolve_recovery(:restore)
    recovered = current.buffers.values.select { |buffer| buffer.path == recovered_path }
    assert_equal 1, recovered.length
    assert_equal "dirty disk recovered\n", recovered.first.text
    assert_equal requested_path, current.editor.buffer.path
    assert_equal "disk requested\n", current.editor.buffer.text
  ensure
    window&.on_close { true }
    window&.close
  end

  def test_recovery_activates_a_pane_whose_eligible_tab_was_saved
    crashed = workspace
    small = crashed.new_buffer
    crashed.split
    large = crashed.new_buffer
    crashed.close_editor(crashed.active_pane.editors.first, discard: true)
    small.insert_text("small draft")
    large.insert_text("x" * (Canopus::Workspace::Recoverable::MAX_DRAFT_BYTES + 1))
    assert_equal 1, crashed.panes.index(crashed.active_pane)
    assert crashed.poll_recovery(force: true)
    snapshot = Dir.glob(File.join(crashed.recovery_directory, "*.json")).fetch(0)
    assert_equal 0, JSON.parse(File.read(snapshot)).fetch("active_pane")
    crashed.preserve_recovery!
    crashed.close
    @workspaces.delete(crashed)

    current = workspace
    assert current.offer_recovery
    assert current.resolve_recovery(:restore)
    assert_equal 0, current.panes.index(current.active_pane)
    assert_equal "small draft", current.editor.buffer.text
  end

  def test_headless_cli_keeps_the_requested_file_active_without_offering_recovery
    leave_recovery_snapshot
    target = File.join(@root, "target.rb")
    image = File.join(@root, "frame.png")
    File.write(target, "puts :target\n")
    observed = {}
    constructor = Canopus::Controller.method(:new)
    replacement = lambda do |current, window, offer_recovery: true|
      controller = constructor.call(current, window, offer_recovery: offer_recovery)
      observed[:offer_recovery] = offer_recovery
      observed[:path] = current.editor.buffer.path
      observed[:palette] = current.palette
      controller
    end
    error = StringIO.new
    result = Canopus::Controller.stub(:new, replacement) do
      Canopus::CLI.main(["--project", @root, "--headless", image, "--size", "160x100", target],
        output: StringIO.new, error: error)
    end
    assert_equal 0, result, error.string
    refute observed[:offer_recovery]
    assert_equal File.realpath(target), observed[:path]
    assert_nil observed[:palette]
  end

  def test_saved_or_oversized_buffers_remove_stale_snapshot
    current = workspace
    editor = current.new_buffer
    editor.insert_text("small")
    assert current.poll_recovery(force: true)
    snapshot = Dir.glob(File.join(current.recovery_directory, "*.json")).fetch(0)
    editor.buffer.save(File.join(@root, "saved.txt"))
    refute current.poll_recovery(force: true)
    refute File.exist?(snapshot)

    large = current.new_buffer
    large.insert_text("x" * (Canopus::Workspace::Recoverable::MAX_DRAFT_BYTES + 1))
    refute current.poll_recovery(force: true)
    assert_empty Dir.glob(File.join(current.recovery_directory, "*.json"))
  end

  def test_recovery_settings_are_validated
    assert_equal({"enabled" => true, "interval" => 5_000}, Canopus::Settings.new["recovery"])
    assert_raises(Canopus::Error) { Canopus::Settings.new("recovery" => {"interval" => 99}) }
    assert_raises(Canopus::Error) { Canopus::Settings.new("recovery" => {"enabled" => "yes"}) }
  end
end
