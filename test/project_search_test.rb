# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "tmpdir"
require "stringio"

class ProjectSearchTest < Minitest::Test
  Worker = Canopus::Project.const_get(:SearchWorker, false)

  def with_project
    Dir.mktmpdir("canopus-search-") { |root| yield Canopus::Project.new(root) }
  end

  def record_children
    pids, spawn = [], Process.method(:spawn)
    Process.stub(:spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |pid| pids << pid } }) { yield pids }
  ensure
    pids.each { |pid| assert_raises(Errno::ECHILD, "child #{pid} was not reaped") { Process.waitpid(pid, Process::WNOHANG) } }
  end

  def test_actual_spawn_workers_without_fork_match_independent_utf8_oracle
    with_project do |project|
      corpus = {"b.rb" => "日本 apple apple\r\n😀 apple\n", "a.txt" => "Apple\n", "a/z.rb" => "apple\n", "a.rb" => "apple\n"}
      corpus.each do |path, text|
        FileUtils.mkdir_p(File.dirname(project.path(path)))
        File.binwrite(project.path(path), text)
      end
      expected = corpus.sort.flat_map do |path, text|
        offset = 0
        text.lines.each_with_index.flat_map do |line, index|
          found = []
          line.to_enum(:scan, /apple/i).each do
            match = Regexp.last_match
            found << [path, index + 1, match.begin(0) + 1, offset + match.pre_match.bytesize, line.chomp, match[0]]
          end
          offset += line.bytesize
          found
        end
      end
      record_children do |pids|
        check = lambda do |*|
          assert_equal expected, project.search("apple", case_sensitive: false, workers: 3).map(&:to_a)
        end
        Process.respond_to?(:fork) ? Process.stub(:fork, ->(*) { flunk "search must not use fork" }, &check) : check.call
        assert_equal 3, pids.length
      end
      assert_equal expected, project.search(/apple/i, workers: 1).map(&:to_a)
    end
  end

  def test_limit_is_deterministic_and_stops_scanning_with_shared_line_text
    with_project do |project|
      %w[a b c d].each { |name| File.binwrite(project.path(name), "日x" * 250_000) }
      [1, 4].each do |workers|
        record_children do
          results = project.search(/x/, workers: workers, limit: 257)
          assert_equal 257, results.length
          assert_equal ["a"], results.map(&:path).uniq
          assert_equal((0...257).map { |n| n * 4 + 3 }, results.map(&:byte_offset))
          assert_equal 1, results.map { |hit| hit.text.object_id }.uniq.length
          assert_equal 1_000_000, results.first.text.bytesize
        end
      end
      messages = []
      Worker.scan(project.root, %w[a b], /x/, Worker::MAX_FILE_BYTES, 3) { |message| messages << message }
      assert_equal [:line, :matches], messages.map(&:first)
      assert_equal 3, messages.last[1].length
    end
  end

  def test_limit_across_partitions_and_missing_files
    with_project do |project|
      %w[a b c d e].each_with_index { |name, index| File.binwrite(project.path(name), "needle\n" * index) }
      expected = project.search("needle", workers: 1).first(5)
      assert_equal expected, project.search("needle", workers: 4, limit: 5, paths: %w[e d c missing b a])
    end
  end

  def test_seeded_unicode_files_and_patterns_match_single_worker
    with_project do |project|
      random = Random.new(814)
      alphabet = ["a", "b", " ", "\t", "日", "😀", "\n", "\r\n"]
      13.times do |index|
        File.binwrite(project.path("#{index}.txt"), Array.new(160) { alphabet.sample(random: random) }.join)
      end
      [/a/, /[ab]+/, /日|😀/, /(?=b)/, /\s+/, /^/, /$/].each do |pattern|
        oracle = project.search(pattern, workers: 1)
        assert_equal oracle, project.search(pattern, workers: 4)
        assert_equal oracle.first(9), project.search(pattern, workers: 3, limit: 9)
      end
    end
  end

  def test_zero_width_and_newline_matches_retain_byte_offsets
    with_project do |project|
      %w[a b].each { |name| File.binwrite(project.path(name), "日😀\r\n") }
      [/(?=.)/, /\r?\n/, /$/].each do |expression|
        assert_equal project.search(expression, workers: 1), project.search(expression, workers: 2)
      end
      assert_equal [0, 3, 7], project.search(/(?=.)/, workers: 2, paths: ["a"]).map(&:byte_offset)
    end
  end

  def test_entire_file_is_validated_before_any_matches_are_published
    with_project do |project|
      File.binwrite(project.path("binary"), "needle\n" + "a" * 100_000 + "\0")
      File.binwrite(project.path("encoding"), "needle\n" + "a" * 100_000 + "\xff".b)
      File.binwrite(project.path("valid"), "needle\n")
      [1, 3].each { |workers| assert_equal ["valid"], project.search("needle", workers: workers).map(&:path) }
    end
  end

  def test_cancel_during_serial_file_reads_and_matches_discards_partial_results
    with_project do |project|
      File.binwrite(project.path("large"), "x" * 1_000_000)
      [6, 30].each do |cancel_at|
        calls = 0
        assert_empty project.search(/x/, workers: 1, cancelled: -> { (calls += 1) >= cancel_at })
        assert_equal cancel_at, calls
      end
    end
  end

  def test_cancel_during_parallel_reads_stops_children_and_reader_threads
    with_project do |project|
      %w[a b c d].each { |name| File.binwrite(project.path(name), "x" * 4_000_000) }
      before = Thread.list
      record_children do |pids|
        cancellation_started = nil
        cancelled = lambda do
          next false if pids.length < 4
          cancellation_started ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - cancellation_started > 0.1
        end
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_empty project.search(/x/, workers: 4, cancelled: cancelled)
        assert_equal 4, pids.length
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 3
      end
      assert_empty Thread.list - before
    end
  end

  def test_child_crash_and_spawn_failure_do_not_leave_processes
    with_project do |project|
      %w[a b].each { |name| File.binwrite(project.path(name), "x") }
      spawn, pids = Process.method(:spawn), []
      replacement = lambda do |*args, **options|
        pid = spawn.call(*args[0...-1], "-e", "exit! 17", **options)
        pids << pid
        pid
      end
      Process.stub(:spawn, replacement) { assert_raises(IOError, EOFError, Errno::EPIPE) { project.search("x", workers: 2) } }
      pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
      count, children = 0, []
      Process.stub(:spawn, ->(*args, **options) { (count += 1) == 2 ? (raise Errno::EAGAIN) : spawn.call(*args, **options).tap { |pid| children << pid } }) do
        assert_raises(Errno::EAGAIN) { project.search("x", workers: 2) }
      end
      children.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
    end
  end

  def test_framing_rejects_truncation_oversize_and_invalid_payload
    value = [:line, "日本.rb", 1, 0, "file text\n"]
    io = StringIO.new("".b)
    Worker.write_frame(io, value)
    io.rewind
    assert_equal value, Worker.read_frame(io)
    ["", "\0", [12].pack("N") + "short"].each do |bytes|
      assert_raises(EOFError) { Worker.read_frame(StringIO.new(bytes)) }
    end
    [0, Worker::MAX_FRAME_BYTES + 1].each do |size|
      assert_raises(IOError) { Worker.read_frame(StringIO.new([size].pack("N"))) }
    end
    assert_raises(IOError) { Worker.read_frame(StringIO.new([3].pack("N") + "bad")) }
  end

  def test_regex_timeout_survives_child_serialization
    with_project do |project|
      %w[a b].each { |name| File.binwrite(project.path(name), "a" * 20_000 + "!") }
      expression = Regexp.new('^(a+)+\\1$', timeout: 0.001)
      assert_raises(Regexp::TimeoutError) { project.search(expression, workers: 1) }
      error = assert_raises(IOError) { project.search(expression, workers: 2) }
      assert_match(/Regexp::TimeoutError/, error.message)
    end
  end

  def test_input_bounds_and_hard_file_limit
    with_project do |project|
      File.binwrite(project.path("one"), "x")
      [0, -1, 33, 1.5].each { |workers| assert_raises(ArgumentError) { project.search("x", workers: workers) } }
      [-1, "10"].each { |max_size| assert_raises(ArgumentError) { project.search("x", max_size: max_size) } }
      assert_raises(ArgumentError) { project.search("x", limit: 0) }
      assert_raises(ArgumentError) { project.search("x", paths: ["../outside"]) }
      assert_raises(ArgumentError) { project.search("x", paths: ["nul\0path"]) }
      File.open(project.path("large"), "wb") { |io| io.truncate(Worker::MAX_FILE_BYTES + 1) }
      assert_empty project.search(/./, max_size: nil, paths: ["large"])
      assert_equal ["one"], project.search("x", max_size: nil).map(&:path)
    end
  end
end
