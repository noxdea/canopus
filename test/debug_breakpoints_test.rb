# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "tmpdir"

class DebugBreakpointsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-breakpoints-")
    @registries = []
    @buffers = []
  end

  def teardown
    @registries.each(&:close)
    @buffers.each(&:close)
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def test_crud_is_immutable_and_persists_unopened_files
    registry = build_registry
    path = File.join(@root, "lib", "missing.rb")
    entry = registry.add(path, 12, condition: "value > 1")

    assert_equal [entry], registry.entries
    assert_equal [entry], registry.for_path("lib/missing.rb")
    assert_equal "lib/missing.rb", entry.path
    assert registry.entries.frozen?
    assert entry.path.frozen?
    assert entry.condition.frozen?
    document = JSON.parse(File.read(storage_path))
    assert_equal 2, document["version"]
    assert_equal({"path" => "lib/missing.rb", "line" => 12, "condition" => "value > 1",
      "hit_condition" => nil, "log_message" => nil, "enabled" => true},
      document["breakpoints"].first)
    assert_empty Dir.children(File.join(@root, ".canopus")) - ["breakpoints.json"]

    reloaded = build_registry
    assert_equal registry.entries, reloaded.entries
  end

  def test_toggle_remove_and_update
    registry = build_registry
    path = File.join(@root, "example.rb")
    first = registry.toggle(path, 3)
    assert_equal 3, first.line
    assert_nil registry.toggle(path, 3)
    assert_empty registry.entries

    registry.add(path, 3)
    updated = registry.update(path, 3, new_line: 5, condition: "ready?")
    assert_equal [5, "ready?"], [updated.line, updated.condition]
    assert_equal updated, registry.update(path, 5)
    registry.add(path, 6)
    assert_raises(Canopus::Error) { registry.update(path, 5, new_line: 6) }
    assert registry.remove(path, 5)
    refute registry.remove(path, 5)
    assert_raises(Canopus::Error) { registry.update(path, 99, condition: "x") }
  end

  def test_v1_entries_migrate_to_dap_ready_v2_fields
    FileUtils.mkdir_p(File.dirname(storage_path))
    write_document("version" => 1, "breakpoints" => [
      {"path" => "legacy.rb", "line" => 4, "condition" => "ready?"}
    ])

    registry = build_registry
    legacy = registry.entries.first
    assert_equal ["legacy.rb", 4, "ready?", nil, nil, true],
      [legacy.path, legacy.line, legacy.condition, legacy.hit_condition, legacy.log_message, legacy.enabled]

    updated = registry.update("legacy.rb", 4, hit_condition: "5", log_message: "value={value}", enabled: false)
    assert_equal ["5", "value={value}", false], [updated.hit_condition, updated.log_message, updated.enabled]
    document = JSON.parse(File.read(storage_path))
    assert_equal 2, document["version"]
    assert_equal({"path" => "legacy.rb", "line" => 4, "condition" => "ready?", "hit_condition" => "5",
      "log_message" => "value={value}", "enabled" => false}, document["breakpoints"].first)
  end

  def test_dap_fields_are_bounded_immutable_and_strictly_typed
    registry = build_registry
    path = File.join(@root, "example.rb")
    entry = registry.add(path, 1, hit_condition: "10", log_message: "stopped", enabled: false)
    assert entry.hit_condition.frozen?
    assert entry.log_message.frozen?
    refute entry.enabled

    assert_raises(Canopus::Error) { registry.add(path, 2, hit_condition: "bad\ncount") }
    assert_raises(Canopus::Error) { registry.add(path, 2, log_message: "x" * 4_097) }
    assert_raises(Canopus::Error) { registry.add(path, 2, enabled: nil) }
    assert_raises(Canopus::Error) { registry.add(path, 2, enabled: 1) }
  end

  def test_leading_insertion_tracks_and_undo_redo_restore_positions
    path, buffer = buffer_for("one\ntwo\nthree\nfour\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 3)

    buffer.edit([[0...0, "inserted\n" * 10]])
    assert_equal [13], registry.for_path(path).map(&:line)
    registry.flush
    assert_equal 13, JSON.parse(File.read(storage_path))["breakpoints"].first["line"]
    assert buffer.undo
    assert_equal [3], registry.for_path(path).map(&:line)
    assert buffer.redo
    assert_equal [13], registry.for_path(path).map(&:line)
  end

  def test_same_offset_insertions_map_breakpoints_anchors_and_editor_selections
    path, buffer = buffer_for("target\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 1)
    editor = Canopus::Editor.new(buffer)
    editor.select(0)
    anchor = buffer.anchor(0)
    insertions = 9.times.map { |index| [0...0, "insert-#{index}\n"] }
    inserted = insertions.map(&:last).join

    buffer.begin_undo_group
    patch = buffer.edit(insertions)
    buffer.edit([[buffer.rope.bytesize...buffer.rope.bytesize, "tail"]])
    buffer.end_undo_group

    assert_equal "#{inserted}target\ntail", buffer.text
    assert_equal insertions.map(&:last), patch.edits.map(&:new_text)
    patch.edits.each { |edit| assert_equal edit.new_text, patch.after.byteslice(edit.new_range).to_s }
    assert_equal inserted.bytesize, patch.map_offset(0)
    assert_equal 0, patch.inverse.map_offset(inserted.bytesize)
    assert_equal inserted.bytesize, buffer.history.last.patch.map_offset(0)
    assert_instance_of Canopus::Patch::Composite, buffer.history.last.patch
    assert_equal [inserted.bytesize, inserted.bytesize], [buffer.resolve(anchor), editor.primary.head]
    assert_equal [10], registry.entries.map(&:line)

    assert buffer.undo
    assert_equal "target\n", buffer.text
    assert_equal [0, 0], [buffer.resolve(anchor), editor.primary.head]
    assert_equal [1], registry.entries.map(&:line)
    assert buffer.redo
    assert_equal [inserted.bytesize, inserted.bytesize], [buffer.resolve(anchor), editor.primary.head]
    assert_equal [10], registry.entries.map(&:line)
  ensure
    editor&.dispose
  end

  def test_whole_line_deletion_removes_and_undo_redo_restore_it
    path, buffer = buffer_for("one\ntwo\nthree\nfour\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 3, condition: "stop")
    first = buffer.rope.line_start(2)
    ending = buffer.rope.line_start(3)

    buffer.edit([[first...ending, ""]])
    assert_empty registry.entries
    assert buffer.undo
    assert_equal [[3, "stop"]], registry.entries.map { |entry| [entry.line, entry.condition] }
    assert buffer.redo
    assert_empty registry.entries
  end

  def test_composite_patches_use_each_subpatch_coordinate_space
    path, buffer = buffer_for("one\ntwo\nthree\nfour\nfive\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 4)

    buffer.begin_undo_group
    buffer.edit([[0...0, "before\nagain\n"]])
    assert_equal [6], registry.entries.map(&:line)
    first = buffer.rope.line_start(5)
    ending = buffer.rope.line_start(6)
    buffer.edit([[first...ending, ""]])
    buffer.end_undo_group
    assert_instance_of Canopus::Patch::Composite, buffer.history.last.patch
    assert_empty registry.entries

    assert buffer.undo
    assert_equal [4], registry.entries.map(&:line)
    assert buffer.redo
    assert_empty registry.entries
  end

  def test_a_direct_composite_maps_each_child_before_snapshot
    path, buffer = buffer_for("one\ntwo\nthree\n")
    listener = nil
    buffer.define_singleton_method(:on_edit) do |&callback|
      listener = callback
      Zaniah::Subscription.new {}
    end
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 3)

    before = buffer.rope
    first_changes = [[0...0, "inserted\n"]]
    middle = before.apply_edits(first_changes)
    first = Canopus::Patch.new(before, middle, first_changes)
    start = middle.line_start(3)
    ending = middle.line_start(4)
    second_changes = [[start...ending, ""]]
    after = middle.apply_edits(second_changes)
    second = Canopus::Patch.new(middle, after, second_changes)

    listener.call(first.compose(second))
    assert_empty registry.entries
  end

  def test_weak_snapshots_preserve_deep_undo_and_redo
    path, buffer = buffer_for("one\ntwo\nthree\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2, condition: "deep")
    first = buffer.rope.line_start(1)
    ending = buffer.rope.line_start(2)
    buffer.edit([[first...ending, ""]])
    300.times { buffer.edit([[buffer.rope.bytesize...buffer.rope.bytesize, "x"]]) }
    GC.start

    300.times { assert buffer.undo }
    assert_empty registry.entries
    assert buffer.undo
    assert_equal [[2, "deep"]], registry.entries.map { |entry| [entry.line, entry.condition] }

    301.times { assert buffer.redo }
    assert_empty registry.entries
  end

  def test_manual_change_does_not_invalidate_unrelated_path_history
    first_path, first = buffer_for("one\ntwo\n", name: "first.rb")
    second_path, second = buffer_for("one\ntwo\n", name: "second.rb")
    registry = build_registry
    registry.attach(first).attach(second)
    registry.add(first_path, 2)
    registry.add(second_path, 2)

    first.edit([[0...0, "before\n"]])
    registry.add(second_path, 2, condition: "manual")
    assert first.undo

    assert_equal [[2, nil]], registry.for_path(first_path).map { |entry| [entry.line, entry.condition] }
    assert_equal [[2, "manual"]], registry.for_path(second_path).map { |entry| [entry.line, entry.condition] }
  end

  def test_manual_change_on_attached_path_becomes_the_current_baseline
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    buffer.edit([[0...0, "before\n"]])
    registry.add(path, 3, condition: "manual")

    assert buffer.undo
    assert_equal [[2, "manual"]], registry.entries.map { |entry| [entry.line, entry.condition] }
    assert buffer.redo
    assert_equal [[3, "manual"]], registry.entries.map { |entry| [entry.line, entry.condition] }
  end

  def test_mapped_collisions_keep_the_earlier_original_entry
    path, buffer = buffer_for("one\ntwo\nthree\nfour\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2, condition: "earlier")
    registry.add(path, 3, condition: "later")
    boundary = buffer.rope.line_start(2) - 1

    buffer.edit([[boundary...(boundary + 1), ""]])
    assert_equal [[2, "earlier"]], registry.entries.map { |entry| [entry.line, entry.condition] }
    registry.flush
    assert_equal registry.entries, build_registry.entries
    assert buffer.undo
    assert_equal [[2, "earlier"], [3, "later"]], registry.entries.map { |entry| [entry.line, entry.condition] }
    assert buffer.redo
    assert_equal [[2, "earlier"]], registry.entries.map { |entry| [entry.line, entry.condition] }
  end

  def test_whole_line_replacement_stays_on_first_replacement_line
    ["\n", "\r\n"].each_with_index do |ending, ending_index|
      3.times do |row|
        name = "replace-#{ending_index}-#{row}.rb"
        path, buffer = buffer_for(["first", "middle", "last"].join(ending), name: name)
        registry = build_registry
        registry.attach(buffer)
        registry.add(path, row + 1)
        first = buffer.rope.line_start(row)
        last = row + 1 < buffer.rope.line_count ? buffer.rope.line_start(row + 1) : buffer.rope.bytesize
        replacement = row + 1 < buffer.rope.line_count ? "new#{ending}" : "new"

        buffer.edit([[first...last, replacement]])
        assert_equal [row + 1], registry.for_path(path).map(&:line)
        assert buffer.undo
        assert_equal [row + 1], registry.for_path(path).map(&:line)
        assert buffer.redo
        assert_equal [row + 1], registry.for_path(path).map(&:line)
      end
    end
  end

  def test_full_line_changes_ignore_unrelated_edits_after_coverage
    ["\n", "\r\n"].each_with_index do |ending, ending_index|
      {replacement: true, deletion: false, boundary: true}.each_with_index do |(kind, retained), case_index|
        name = "covered-#{ending_index}-#{case_index}.rb"
        path, buffer = buffer_for(["head", "target", "tail", "last"].join(ending), name: name)
        registry = build_registry
        registry.attach(buffer)
        registry.add(path, 2)
        first = buffer.rope.line_start(1)
        content_end = first + buffer.rope.line(1).bytesize
        line_end = buffer.rope.line_start(2)
        after = buffer.rope.line_start(3)
        target = kind == :boundary ? first...content_end : first...line_end
        replacement = kind == :replacement ? "new#{ending}" : ""
        changes = [[0...1, "H"], [target, replacement], [after...(after + 1), "L"]]
        changes << [content_end...content_end, "new"] if kind == :boundary

        buffer.edit(changes.reverse)
        assert_equal retained ? [2] : [], registry.for_path(path).map(&:line)
        assert buffer.undo
        assert_equal [2], registry.for_path(path).map(&:line)
        assert buffer.redo
        assert_equal retained ? [2] : [], registry.for_path(path).map(&:line)
        registry.flush
        assert_equal retained ? [2] : [], build_registry.for_path(path).map(&:line)
      end
    end
  end

  def test_delete_and_same_offset_insert_replace_a_line_in_either_input_order
    ["\n", "\r\n"].each_with_index do |ending, ending_index|
      2.times do |order|
        name = "multi-replace-#{ending_index}-#{order}.rb"
        path, buffer = buffer_for(["one", "target", "three"].join(ending), name: name)
        registry = build_registry
        registry.attach(buffer)
        registry.add(path, 2)
        first = buffer.rope.line_start(1)
        last = first + buffer.rope.line(1).bytesize
        changes = [[first...first, "replacement#{ending}continued"], [first...last, ""]]

        buffer.edit(order.zero? ? changes : changes.reverse)
        assert_equal [2], registry.for_path(path).map(&:line)
        assert buffer.undo
        assert_equal [2], registry.for_path(path).map(&:line)
        assert buffer.redo
        assert_equal [2], registry.for_path(path).map(&:line)
        registry.flush
        assert_equal [2], build_registry.for_path(path).map(&:line)
      end
    end
  end

  def test_multiple_nonempty_edits_replace_a_line_at_the_first_new_offset
    path, buffer = buffer_for("one\ntarget\nthree\n", name: "multiple-nonempty.rb")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    first = buffer.rope.line_start(1)
    middle = first + 3
    last = first + buffer.rope.line(1).bytesize

    buffer.edit([[first...middle, "first\n"], [middle...last, "second"]])
    assert_equal [2], registry.for_path(path).map(&:line)
    assert buffer.undo
    assert_equal [2], registry.for_path(path).map(&:line)
    assert buffer.redo
    assert_equal [2], registry.for_path(path).map(&:line)
    registry.flush
    assert_equal [2], build_registry.for_path(path).map(&:line)
  end

  def test_multi_edit_replacement_uses_an_empty_lines_line_break_identity
    ["\n", "\r\n"].each_with_index do |ending, index|
      path, buffer = buffer_for("one#{ending}#{ending}three", name: "empty-replace-#{index}.rb")
      registry = build_registry
      registry.attach(buffer)
      registry.add(path, 2)
      first = buffer.rope.line_start(1)
      last = buffer.rope.line_start(2)

      buffer.edit([[first...last, ""], [first...first, "replacement#{ending}"]])
      assert_equal [2], registry.for_path(path).map(&:line)
      assert buffer.undo
      assert_equal [2], registry.for_path(path).map(&:line)
      assert buffer.redo
      assert_equal [2], registry.for_path(path).map(&:line)
    end
  end

  def test_split_deletions_remove_a_line_and_undo_restores_it
    path, buffer = buffer_for("one\ntarget\nthree\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    first = buffer.rope.line_start(1)
    middle = first + 3
    ending = first + buffer.rope.line(1).bytesize

    buffer.edit([[first...middle, ""], [middle...ending, ""]])
    assert_empty registry.entries
    assert buffer.undo
    assert_equal [2], registry.entries.map(&:line)
    assert buffer.redo
    assert_empty registry.entries
    registry.flush
    assert_empty build_registry.for_path(path)
  end

  def test_line_deletion_handles_first_middle_and_last_with_lf_and_crlf
    registry = build_registry
    ["\n", "\r\n"].each_with_index do |ending, ending_index|
      3.times do |row|
        name = "delete-#{ending_index}-#{row}.rb"
        path, buffer = buffer_for(["first", "middle", "last"].join(ending), name: name)
        registry.attach(buffer)
        registry.add(path, row + 1)
        first = buffer.rope.line_start(row)
        last = row + 1 < buffer.rope.line_count ? buffer.rope.line_start(row + 1) : buffer.rope.bytesize

        buffer.edit([[first...last, ""]])
        assert_empty registry.for_path(path)
        assert buffer.undo
        assert_equal [row + 1], registry.for_path(path).map(&:line)
        assert buffer.redo
        assert_empty registry.for_path(path)
      end
    end
    assert_equal [registry], @registries
  end

  def test_removing_the_newline_removes_a_final_empty_line
    registry = build_registry
    ["\n", "\r\n"].each_with_index do |ending, index|
      path, buffer = buffer_for("one#{ending}", name: "empty-#{index}.rb")
      registry.attach(buffer)
      registry.add(path, 2)
      first = buffer.rope.line_start(1) - ending.bytesize

      buffer.edit([[first...buffer.rope.bytesize, ""]])
      assert_empty registry.for_path(path)
      assert buffer.undo
      assert_equal [2], registry.for_path(path).map(&:line)
      assert buffer.redo
      assert_empty registry.for_path(path)
    end
    assert_equal [registry], @registries
  end

  def test_final_empty_line_shifts_when_an_earlier_newline_is_removed
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 3)
    boundary = buffer.rope.line_start(1) - 1

    buffer.edit([[boundary...(boundary + 1), ""]])
    assert_equal [2], registry.entries.map(&:line)
    assert buffer.undo
    assert_equal [3], registry.entries.map(&:line)
    assert buffer.redo
    assert_equal [2], registry.entries.map(&:line)
  end

  def test_line_start_character_replacement_does_not_remove_or_save
    path, buffer = buffer_for("one\ntwo\nthree\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    writes = 0
    original = registry.method(:persist)
    registry.define_singleton_method(:persist) { |values| writes += 1; original.call(values) }

    first = buffer.rope.line_start(1)
    buffer.edit([[first...(first + 1), "T"]])
    assert_equal [2], registry.entries.map(&:line)
    assert_equal 0, writes
  end

  def test_tracked_edit_bursts_are_coalesced_by_one_writer
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    writes = 0
    original = registry.method(:persist)
    registry.define_singleton_method(:persist) { |values| writes += 1; original.call(values) }

    10.times { buffer.edit([[0...0, "line\n"]]) }
    registry.flush

    assert_equal [12], registry.entries.map(&:line)
    assert_equal 1, writes
    assert_equal 12, JSON.parse(File.read(storage_path))["breakpoints"].first["line"]
  end

  def test_background_failure_is_visible_and_the_next_edit_retries_latest_state
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    original = registry.method(:persist)
    failures = 1
    registry.define_singleton_method(:persist) do |values|
      if failures.positive?
        failures -= 1
        raise Canopus::Error, "save failed"
      end
      original.call(values)
    end

    buffer.edit([[0...0, "first\n"]])
    error = assert_raises(Canopus::Error) { registry.flush }
    assert_equal "save failed", error.message
    assert_equal error, registry.error
    assert_equal [3], registry.entries.map(&:line)

    buffer.edit([[0...0, "second\n"]])
    assert_equal [4], registry.entries.map(&:line)
    assert_same registry, registry.flush
    assert_nil registry.error
    assert_equal 4, build_registry.entries.first.line
  end

  def test_mapping_failure_detaches_instead_of_continuing_stale_coordinates
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    before = File.binread(storage_path)
    registry.define_singleton_method(:map_entries) { |*, **| raise Canopus::Error, "mapping failed" }

    capture_io { buffer.edit([[0...0, "first\n"]]) }
    assert_equal [2], registry.entries.map(&:line)
    assert_equal before, File.binread(storage_path)
    assert_match(/mapping failed/, buffer.notification_errors.last.message)

    buffer.edit([[0...0, "second\n"]])
    assert_equal [2], registry.entries.map(&:line)
  end

  def test_manual_write_follows_a_pending_tracked_write
    path, buffer = buffer_for("one\ntwo\n")
    other = File.join(@root, "other.rb")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)

    buffer.edit([[0...0, "before\n"]])
    registry.add(other, 7)

    reloaded = build_registry
    assert_equal [3], reloaded.for_path(path).map(&:line)
    assert_equal [7], reloaded.for_path(other).map(&:line)
  end

  def test_close_and_detach_flush_pending_changes
    first_path, first = buffer_for("one\ntwo\n", name: "first.rb")
    first_registry = build_registry
    first_registry.attach(first)
    first_registry.add(first_path, 2)
    first.edit([[0...0, "before\n"]])
    first_registry.close
    assert_equal 3, build_registry.for_path(first_path).first.line

    second_path, second = buffer_for("one\ntwo\n", name: "second.rb")
    second_registry = build_registry
    second_registry.attach(second)
    second_registry.add(second_path, 2)
    second.edit([[0...0, "before\n"]])
    assert second_registry.detach(second)
    assert_equal 3, build_registry.for_path(second_path).first.line
  end

  def test_close_reports_a_pending_failure_and_stops_the_writer
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    registry.define_singleton_method(:persist) { |_| raise Canopus::Error, "close failed" }
    buffer.edit([[0...0, "before\n"]])

    error = assert_raises(Canopus::Error) { registry.close }
    assert_equal "close failed", error.message
    refute registry.instance_variable_get(:@save_worker).alive?
  end

  def test_save_as_switches_to_new_path_without_changing_old_entries
    old_path, buffer = buffer_for("one\ntwo\n", name: "old.rb")
    new_path = File.join(@root, "new.rb")
    File.write(new_path, "one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(old_path, 2, condition: "old")
    registry.add(new_path, 2, condition: "new")

    buffer.save(new_path, force: true)
    buffer.edit([[0...0, "before\n"]])

    assert_equal [[2, "old"]], registry.for_path(old_path).map { |entry| [entry.line, entry.condition] }
    assert_equal [[3, "new"]], registry.for_path(new_path).map { |entry| [entry.line, entry.condition] }
  end

  def test_invalid_relocation_detaches_without_changing_registry
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    before = File.binread(storage_path)
    outside = File.join(File.dirname(@root), "outside.rb")

    buffer.relocate(outside)
    capture_io { buffer.edit([[0...0, "before\n"]]) }
    assert_equal [2], registry.entries.map(&:line)
    assert_equal before, File.binread(storage_path)
    assert_match(/outside the workspace/, buffer.notification_errors.last.message)

    buffer.relocate(path)
    buffer.edit([[0...0, "detached\n"]])
    assert_equal [2], registry.entries.map(&:line)
  end

  def test_relocation_through_an_inside_alias_uses_the_canonical_path
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    original_path, buffer = buffer_for("one\ntwo\n", name: "original.rb")
    target_path = File.join(@root, "target.rb")
    alias_path = File.join(@root, "alias.rb")
    File.write(target_path, "one\ntwo\n")
    begin
      File.symlink(target_path, alias_path)
    rescue NotImplementedError, Errno::EPERM
      skip "symlink creation is unavailable"
    end
    registry = build_registry
    registry.attach(buffer)
    registry.add(original_path, 2, condition: "old")
    registry.add(target_path, 2, condition: "target")

    buffer.relocate(alias_path)
    buffer.edit([[0...0, "before\n"]])

    assert_equal [[2, "old"]], registry.for_path(original_path).map { |entry| [entry.line, entry.condition] }
    assert_equal [[3, "target"]], registry.for_path(target_path).map { |entry| [entry.line, entry.condition] }
  end

  def test_relocation_through_an_outside_symlink_detaches
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    path, buffer = buffer_for("one\ntwo\n")
    outside = Dir.mktmpdir("canopus-breakpoints-relocation-")
    begin
      target = File.join(outside, "outside.rb")
      link = File.join(@root, "outside-link.rb")
      File.write(target, "one\ntwo\n")
      begin
        File.symlink(target, link)
      rescue NotImplementedError, Errno::EPERM
        skip "symlink creation is unavailable"
      end
      registry = build_registry
      registry.attach(buffer)
      registry.add(path, 2)

      buffer.relocate(link)
      capture_io { buffer.edit([[0...0, "before\n"]]) }

      assert_equal [2], registry.entries.map(&:line)
      assert_match(/outside the workspace/, buffer.notification_errors.last.message)
      buffer.relocate(path)
      buffer.edit([[0...0, "detached\n"]])
      assert_equal [2], registry.entries.map(&:line)
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  def test_attach_rejects_a_second_buffer_for_the_same_path
    path, first = buffer_for("one\ntwo\n")
    second = Canopus::Buffer.new("one\ntwo\n", path: path)
    @buffers << second
    registry = build_registry

    assert_same registry, registry.attach(first)
    assert_same registry, registry.attach(first)
    error = assert_raises(Canopus::Error) { registry.attach(second) }
    assert_match(/already attached/, error.message)
  end

  def test_attach_rejects_a_symlink_alias_of_an_attached_path
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    path, first = buffer_for("one\ntwo\n", name: "target.rb")
    alias_path = File.join(@root, "alias-target.rb")
    begin
      File.symlink(path, alias_path)
    rescue NotImplementedError, Errno::EPERM
      skip "symlink creation is unavailable"
    end
    second = Canopus::Buffer.new("one\ntwo\n", path: alias_path)
    @buffers << second
    registry = build_registry

    registry.attach(first)
    assert_raises(Canopus::Error) { registry.attach(second) }
  end

  def test_detach_allows_another_buffer_to_attach_the_same_path
    path, first = buffer_for("one\ntwo\n")
    second = Canopus::Buffer.new("one\ntwo\n", path: path)
    @buffers << second
    registry = build_registry
    registry.attach(first)

    assert registry.detach(first)
    assert_same registry, registry.attach(second)
    registry.add(path, 2)
    second.edit([[0...0, "before\n"]])
    assert_equal [3], registry.entries.map(&:line)
  end

  def test_detach_and_close_release_edit_subscriptions
    path, buffer = buffer_for("one\ntwo\n")
    registry = build_registry
    registry.attach(buffer)
    registry.add(path, 2)
    assert registry.detach(buffer)
    refute registry.detach(buffer)
    buffer.edit([[0...0, "detached\n"]])
    assert_equal [2], registry.entries.map(&:line)

    registry.attach(buffer)
    registry.close
    buffer.edit([[0...0, "closed\n"]])
    assert_equal [2], registry.entries.map(&:line)
    assert_raises(Canopus::Error) { registry.add(path, 4) }
  end

  def test_input_bounds_are_enforced
    registry = build_registry
    path = File.join(@root, "example.rb")
    [0, -1, 2_147_483_648, 1.5].each { |line| assert_raises(Canopus::Error) { registry.add(path, line) } }
    assert_raises(Canopus::Error) { registry.add(path, 1, condition: "") }
    assert_raises(Canopus::Error) { registry.add(path, 1, condition: "x" * 4_097) }
    assert_raises(Canopus::Error) { registry.add(path, 1, condition: "bad\ncondition") }
    assert_raises(Canopus::Error) { registry.add(path, 1, condition: "\xff".b) }
    ["\t", "\x01", "\x7f"].each do |control|
      assert_raises(Canopus::Error) { registry.add(path, 1, condition: "bad#{control}condition") }
      assert_raises(Canopus::Error) { registry.add(File.join(@root, "bad#{control}.rb"), 1) }
    end
    assert_raises(Canopus::Error) { registry.add(File.join(@root, "..", "outside.rb"), 1) }
  end

  def test_invalid_oversized_and_escaping_files_are_rejected
    FileUtils.mkdir_p(File.dirname(storage_path))
    File.write(storage_path, "not json")
    assert_raises(Canopus::Error) { build_registry }

    File.binwrite(storage_path, " " * (Canopus::Debug::Breakpoints::MAX_BYTES + 1))
    assert_raises(Canopus::Error) { build_registry }

    write_document("version" => 3, "breakpoints" => [])
    assert_raises(Canopus::Error) { build_registry }
    write_document("version" => 1, "breakpoints" => [
      {"path" => "../escape.rb", "line" => 1, "condition" => nil}
    ])
    assert_raises(Canopus::Error) { build_registry }

    entries = Array.new(Canopus::Debug::Breakpoints::MAX_ENTRIES + 1) do |index|
      {"path" => "file#{index}.rb", "line" => 1, "condition" => nil}
    end
    write_document("version" => 1, "breakpoints" => entries)
    assert_raises(Canopus::Error) { build_registry }
  end

  def test_storage_and_breakpoint_symlink_escapes_are_rejected
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    outside = Dir.mktmpdir("canopus-breakpoints-outside-")
    begin
      File.symlink(outside, File.join(@root, ".canopus"))
      assert_raises(Canopus::Error) { build_registry }
      File.unlink(File.join(@root, ".canopus"))

      FileUtils.mkdir_p(File.join(@root, ".canopus"))
      File.write(File.join(outside, "breakpoints.json"), JSON.generate("version" => 1, "breakpoints" => []))
      File.symlink(File.join(outside, "breakpoints.json"), storage_path)
      assert_raises(Canopus::Error) { build_registry }
      File.unlink(storage_path)

      File.symlink(outside, File.join(@root, "linked"))
      registry = build_registry
      assert_raises(Canopus::Error) { registry.add(File.join(@root, "linked", "file.rb"), 1) }

      File.symlink(File.join(outside, "missing"), File.join(@root, "broken"))
      assert_raises(Canopus::Error) { registry.add(File.join(@root, "broken", "file.rb"), 1) }
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  def test_nonexistent_paths_are_canonical_and_macos_aliases_are_safe
    registry = build_registry
    path = File.join(@root, "missing", "file.rb")
    assert_equal "missing/file.rb", registry.add(path, 1).path
    return unless /darwin/ =~ RUBY_PLATFORM && @root.start_with?("/var/")
    assert registry.root.start_with?("/private/var/")
    assert_equal [1], registry.for_path(path).map(&:line)
  end

  private

  def build_registry
    registry = Canopus::Debug::Breakpoints.new(root: @root)
    @registries << registry
    registry
  end

  def buffer_for(text, name: "source.rb")
    path = File.join(@root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    buffer = Canopus::Buffer.new(text, path: path)
    @buffers << buffer
    [path, buffer]
  end

  def storage_path
    File.join(@root, ".canopus", "breakpoints.json")
  end

  def write_document(document)
    File.binwrite(storage_path, JSON.generate(document))
  end
end
