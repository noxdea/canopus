# frozen_string_literal: true

require_relative "test_helper"

class DisplayMapBackgroundTest < Minitest::Test
  def setup = @maps = []
  def teardown = @maps.each(&:dispose)

  def map(buffer, **options)
    value = Canopus::DisplayMap.new(buffer, background_threshold: 0, **options)
    @maps << value
    value
  end

  def finish(mapping)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    while mapping.pending?
      mapping.poll(max_lines: 17)
      raise "wrap calculation did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
    assert_equal [mapping.tree.size, mapping.tree.size], mapping.progress
    assert mapping.tree.check_invariants!
  end

  def wait_for_queue(mapping)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until mapping.instance_variable_get(:@worker).results.length.positive?
      raise "wrap worker did not produce output" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end

  def assert_same_display(expected, actual)
    assert_equal expected.row_count, actual.row_count
    expected.row_count.times do |row|
      assert_equal expected.row(row), actual.row(row), "row #{row}"
      assert_equal expected.source_row(row), actual.source_row(row), "source #{row}"
      [0, expected.row(row).text.length].each do |column|
        point = Canopus::DisplayPoint.new(row, column)
        assert_equal expected.to_buffer(point), actual.to_buffer(point)
      end
    end
  end

  def test_provisional_rows_do_not_change_until_foreground_poll
    buffer = Canopus::Buffer.new("a\tbcd\n日本語日本語\nlast")
    mapping = map(buffer, wrap_width: 4)
    assert mapping.pending?
    assert_equal 3, mapping.row_count
    assert_equal "a   bcd", mapping.row(0).text
    original_tree = mapping.tree
    wait_for_queue(mapping)
    assert_same original_tree, mapping.tree
    assert_equal "a   bcd", mapping.row(0).text
    assert mapping.poll(max_lines: 1)
    assert_equal [1, 3], mapping.progress
    assert_equal "a   ", mapping.row(0).text
    finish(mapping)
    oracle = map(buffer, wrap_width: 4, background_threshold: nil)
    assert_same_display(oracle, mapping)
    refute mapping.poll
  end

  def test_completed_lines_are_reused_and_old_generations_do_not_overwrite_edits
    buffer = Canopus::Buffer.new(("long\t日本 row\n" * 200))
    mapping = map(buffer, wrap_width: 8)
    finish(mapping)
    untouched = mapping.tree[0]
    buffer.edit([[buffer.rope.line_start(100)...buffer.rope.line_start(101), "changed\nextra\n"]])
    assert mapping.pending?
    assert_same untouched, mapping.tree[0]
    assert_equal 3, mapping.tree.summary.pending_rows # Includes the edited boundary's unchanged following line.
    wait_for_queue(mapping)
    mapping.wrap_width = 3
    buffer.edit([[0...4, "latest"]])
    mapping.wrap_width = 7
    finish(mapping)
    oracle = map(buffer, wrap_width: 7, background_threshold: nil)
    assert_same_display(oracle, mapping)
    assert_equal "latest", buffer.text[0, 6]
  end

  def test_folds_tabs_and_blocks_are_consistent_during_and_after_background_work
    buffer = Canopus::Buffer.new("one\ntwo\nthree\nfour\taaaaa\nlast")
    mapping = map(buffer, wrap_width: 3)
    mapping.fold(3...13)
    assert_equal "one…", mapping.row(0).text
    assert_equal 13, mapping.to_buffer(Canopus::DisplayPoint.new(0, 4))
    mapping.insert_block(:message, row: 3, text: "first\nsecond")
    mapping.tab_size = 2
    finish(mapping)
    oracle = map(buffer, wrap_width: 3, tab_size: 2, background_threshold: nil)
    oracle.fold(3...13)
    oracle.insert_block(:message, row: 3, text: "first\nsecond")
    assert_same_display(oracle, mapping)
    untouched = mapping.tree[4]
    mapping.unfold(4)
    assert_same untouched, mapping.tree[4]
    mapping.remove_block(:message)
    finish(mapping)
    oracle.unfold(4)
    oracle.remove_block(:message)
    assert_same_display(oracle, mapping)
  end

  def test_partial_poll_budget_and_bounded_queue
    buffer = Canopus::Buffer.new("abcdef\n" * 1000)
    mapping = map(buffer, wrap_width: 2)
    worker = mapping.instance_variable_get(:@worker)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until worker.results.length == 8
      raise "queue did not fill" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
    assert_equal [0, 1001], mapping.progress
    assert mapping.poll(max_lines: 3)
    assert_equal [3, 1001], mapping.progress
    assert_operator worker.results.length, :<=, 8
    mapping.dispose
    refute worker.thread.alive?
    refute mapping.pending?
    refute mapping.poll
    mapping.dispose
  end

  def test_large_initial_open_and_long_line_provisional_window_are_bounded
    buffer = Canopus::Buffer.new("日" * 400_000)
    mapping = map(buffer, wrap_width: 80, background_threshold: Canopus::DisplayMap::BACKGROUND_THRESHOLD)
    assert mapping.pending?
    assert_equal 0, mapping.recomputed_lines
    assert_operator mapping.row(0).text.bytesize, :<=, 16_384
    target = buffer.rope.bytesize - 9
    point = mapping.to_display(target)
    assert_equal target, mapping.to_buffer(point)
    assert mapping.row(0).text.valid_encoding?
    worker = mapping.instance_variable_get(:@worker)
    mapping.dispose
    refute worker.thread.alive?
  end

  def test_threshold_crossings_and_undo_discard_old_jobs
    buffer = Canopus::Buffer.new("small")
    mapping = map(buffer, wrap_width: 3, background_threshold: 100)
    refute mapping.pending?
    buffer.edit([[5...5, "日本 row\n" * 100]])
    assert mapping.pending?
    buffer.undo
    refute mapping.pending?
    assert_equal "sma", mapping.row(0).text
    buffer.redo
    assert mapping.pending?
    finish(mapping)
    assert_same_display(map(buffer, wrap_width: 3, background_threshold: nil), mapping)
  end

  def test_worker_errors_propagate_on_poll_and_shutdown_is_bounded
    mapping = map(Canopus::Buffer.new("a\nb"), wrap_width: 1, background_threshold: nil)
    worker = Canopus::DisplayMap.const_get(:Worker).new
    builder = Object.new
    builder.define_singleton_method(:line) { |*| raise "wrap test failure" }
    mapping.instance_variable_set(:@worker, worker)
    worker.submit(mapping.instance_variable_get(:@generation), mapping.tree, builder, 0)
    wait_for_queue(mapping)
    error = assert_raises(RuntimeError) { mapping.poll }
    assert_equal "wrap test failure", error.message
    assert_same error, mapping.layout_error
    refute mapping.pending?
    refute worker.thread.alive?
    assert_equal "a", mapping.row(0).text
  ensure
    mapping&.dispose
  end

  def test_cancel_repeated_settings_changes_uses_only_one_worker
    mapping = map(Canopus::Buffer.new("日本\tline\n" * 1000), wrap_width: 3)
    worker = mapping.instance_variable_get(:@worker)
    20.times do |index|
      mapping.wrap_width = index + 1
      mapping.tab_size = index % 4 + 1
      assert_same worker, mapping.instance_variable_get(:@worker)
    end
    finish(mapping)
    mapping.dispose
    refute worker.thread.alive?
  end

  def test_unicode_newline_fold_pipeline_matches_unwrapped_source
    ["\n", "\r", "\r\n", "\u2028", "\u2029"].each do |separator|
      buffer = Canopus::Buffer.new("日本#{separator}語#{separator}")
      mapping = map(buffer, wrap_width: 1)
      assert_equal ["日本", "語", ""], mapping.each_row.map { |row, _| row.text }
      finish(mapping)
      assert_equal ["日", "本", "語", ""], mapping.each_row.map { |row, _| row.text }
    end
  end

  def test_fold_end_remainder_maps_to_its_visible_owner_even_across_chained_folds
    buffer = Canopus::Buffer.new("abc\ndef\nghijk")
    [nil, 0].each do |threshold|
      mapping = map(buffer, background_threshold: threshold)
      mapping.fold(2...5)
      mapping.fold(6...9)
      assert_equal "ab…e…hijk", mapping.row(0).text
      assert_equal Canopus::DisplayPoint.new(0, 6), mapping.to_display(10)
      assert_equal 10, mapping.to_buffer(mapping.to_display(10))
      finish(mapping) if mapping.pending?
      assert_equal Canopus::DisplayPoint.new(0, 6), mapping.to_display(10)
    end
  end

  def test_invalid_inclusive_fold_does_not_mutate_mapping
    mapping = map(Canopus::Buffer.new("abc"), background_threshold: nil)
    assert_raises(RangeError) { mapping.fold(1..3) }
    assert_empty mapping.fold_map.ranges
    mapping.fold(1..1)
    assert_equal "a…c", mapping.row(0).text
  end

  def test_summary_values_and_repeated_row_locations_are_cached_and_immutable
    mapping = map(Canopus::Buffer.new("abcdef\n" * 100), wrap_width: 2, background_threshold: nil)
    line = mapping.tree[0]
    assert_same line.summary, line.summary
    assert_same line.summary, Canopus::DisplayMap::Summary.zero + line.summary
    assert_equal 6, line.summary.project_combined(:display_rows, line.summary)
    assert_raises(FrozenError) { line.summary.display_rows = 999 }
    first = mapping.send(:locate, 10)
    assert_same first, mapping.send(:locate, 10)
    mapping.wrap_width = 4
    refute_same first, mapping.send(:locate, 10)
    257.times { |index| mapping.row(index % mapping.row_count) }
    assert_operator mapping.instance_variable_get(:@location_cache).length, :<=, 256
  end

  def test_seeded_edit_fold_block_and_width_sequences_match_synchronous_oracle
    5.times do |seed|
      random = Random.new(seed)
      buffer = Canopus::Buffer.new("abc\t日本語 tail\n" * 20)
      mapping = map(buffer, wrap_width: 8)
      oracle = map(buffer, wrap_width: 8, background_threshold: nil)
      12.times do |step|
        row = random.rand(buffer.line_count - 1)
        case step % 4
        when 0
          buffer.edit([[buffer.rope.line_start(row)...buffer.rope.line_start(row), "z\n"]])
        when 1
          first = buffer.rope.line_start(row) + 1
          last = buffer.rope.line_start([row + 2, buffer.line_count - 1].min)
          [mapping, oracle].each { |value| value.fold(first...last) } if last > first
        when 2
          [mapping, oracle].each { |value| value.insert_block(:test, row: row, text: "one\ntwo") }
        when 3
          width = random.rand(2..12)
          [mapping, oracle].each { |value| value.wrap_width = width }
        end
        mapping.poll(max_lines: 3)
      end
      finish(mapping)
      assert_same_display(oracle, mapping)
      buffer.line_count.times do |row|
        offset = buffer.rope.line_start(row)
        assert_equal oracle.to_display(offset), mapping.to_display(offset), "seed #{seed}, source #{row}"
      end
    end
  end
end
