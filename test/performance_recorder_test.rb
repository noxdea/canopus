# frozen_string_literal: true

require_relative "test_helper"
require "canopus/performance_recorder"
require "canopus/cli"
require "tmpdir"
require "stringio"
require "open3"
require "rbconfig"

class PerformanceRecorderTest < Minitest::Test
  class Window
    attr_reader :device, :content_size, :scale_factor
    def initialize
      @device = Struct.new(:draw_calls).new(0)
      @content_size = Zaniah::Size.new(320, 200)
      @scale_factor = 2
    end

    def render(value, fail: false)
      100.times { Object.new }
      sleep 0.015 # Includes a synchronous present/wait in the measured boundary.
      raise "render failed" if fail
      @device.draw_calls = 7
      yield if block_given?
      value
    end
  end

  def test_render_boundary_arguments_return_and_bounded_samples
    window = Window.new
    profile = Canopus::PerformanceRecorder.new(window, capacity: 2, sample_capacity: 2, interval: 0.001).start
    assert_equal 0, profile.statistics[:frames]
    assert_nil profile.statistics[:last_frame_ms]
    assert_raises(ArgumentError) { profile.report }
    4.times { |i| assert_equal i, window.render(i) { @called = true } }
    profile.stop
    refute profile.sampler.alive?
    assert @called
    report = profile.report
    assert_equal [3, 4], report[:frames].map { |frame| frame[:frame] }
    assert_equal 4, report[:statistics][:frames]
    assert_operator report[:statistics][:last_frame_ms], :>=, 14
    assert_operator report[:statistics][:last_allocations], :>=, 100
    assert_equal 7, report[:statistics][:last_draw_calls]
    assert_operator report[:sampling][:total_samples], :>, 2
    assert_equal 2, report[:sampling][:retained_samples]
    assert_equal 2, report[:context][:scale_factor]
    assert_equal 320, report[:context][:logical_size][:width]
    assert_match(/Window#render/, report[:measurement][:frame])
    window.render(:after_stop)
    assert_equal 4, profile.statistics[:frames]
    assert_raises(ArgumentError) { profile.start }
  ensure
    profile&.stop
  end

  def test_failed_render_is_recorded_without_claiming_previous_draw_calls
    window = Window.new
    profile = Canopus::PerformanceRecorder.new(window).start
    window.render(:ok)
    error = assert_raises(RuntimeError) { window.render(:bad, fail: true) }
    assert_equal "render failed", error.message
    profile.stop
    frame = profile.report[:frames].last
    refute frame[:completed]
    assert_nil frame[:draw_calls]
    assert_equal 2, profile.statistics[:frames]
  ensure
    profile&.stop
  end

  def test_render_measurement_without_sampling
    window = Window.new
    profile = Canopus::PerformanceRecorder.new(window, sampling: false).start
    assert_nil profile.sampler
    assert_equal :measured, window.render(:measured)
    profile.stop
    report = profile.report
    refute report[:sampling][:enabled]
    assert_equal 0, report[:sampling][:total_samples]
    assert_equal 1, report[:statistics][:frames]
    assert_operator report[:statistics][:last_allocations], :>=, 100
  ensure
    profile&.stop
  end

  def test_allocation_trace_stops_and_reports_locations_without_contents
    profile = Canopus::PerformanceRecorder.new(Window.new, trace_allocations: true).start
    retained = Array.new(20) { String.new("private buffer text") }
    assert_equal __FILE__, ObjectSpace.allocation_sourcefile(retained.first)
    # Ruby retains metadata when tracing stops; after GC a reused object slot
    # can still report its old source. Verify the balanced native stop instead.
    stop_trace = ObjectSpace.method(:trace_object_allocations_stop)
    stops = 0
    ObjectSpace.stub(:trace_object_allocations_stop, -> { stops += 1; stop_trace.call }) do
      profile.stop
      profile.stop
    end
    assert_equal 1, stops
    report = profile.report
    # A bounded live-heap scan is not guaranteed to visit these particular
    # objects once the full application suite has populated a larger heap.
    assert_operator report[:allocation_sites][:examined_objects], :<=, 100_000
    assert_operator report[:allocation_sites][:sites].length, :<=, 2_000
    assert report[:allocation_sites][:sites].all? { |site| site[:file].is_a?(String) && site[:live_objects].positive? }
    refute_includes JSON.generate(report), "private buffer text"
    profile.stop
  ensure
    profile&.stop
  end

  def test_private_atomic_json_and_crash_privacy
    Dir.mktmpdir do |dir|
      path = File.join(dir, "crash.json")
      File.write(path, "previous report")
      File.chmod(0o644, path)
      error = RuntimeError.new("failure\xff".b)
      error.set_backtrace(["/private/project/source.rb:12:in 'render'"])
      Canopus::PerformanceRecorder.write_crash(path, error)
      report = JSON.parse(File.read(path))
      assert_equal "crash", report["kind"]
      assert_equal "RuntimeError", report["exception"]["class"]
      assert_equal "failure�", report["exception"]["message"]
      assert_equal 0o600, File.stat(path).mode & 0o777 unless Gem.win_platform?
      refute report.key?("environment")
      refute report.key?("buffers")
      assert_equal ["crash.json"], Dir.children(dir)
      link = File.join(dir, "link.json")
      File.symlink(path, link)
      assert_raises(ArgumentError) { Canopus::PerformanceRecorder.write_crash(link, error) }
      assert_raises(ArgumentError) { Canopus::PerformanceRecorder.validate_paths([path], protected: [path]) }
      assert_raises(ArgumentError) { Canopus::PerformanceRecorder.validate_paths([path, path]) }
    end
  end

  def test_cli_diagnostics_are_lazy_and_allocation_option_requires_profile
    code = 'require "canopus"; require "canopus/cli"; Canopus::CLI.main(["--help"]); abort "diagnostics loaded" if $LOADED_FEATURES.any? { |path| path.end_with?("canopus/performance_recorder.rb") }; abort "sampler running" if Thread.list.any? { |thread| thread.name == "canopus-profile" }'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", code, chdir: File.expand_path("..", __dir__))
    assert status.success?, stderr
    assert_includes stdout, "--crash-report"
    error = StringIO.new
    assert_equal 1, Canopus::CLI.main(["--trace-allocations"], output: StringIO.new, error: error)
    assert_includes error.string, "requires --profile"
  end

  def test_cli_headless_profile_and_runtime_failure_cleanup
    Dir.mktmpdir do |dir|
      profile_path, crash_path, image_path = %w[profile.json crash.json frame.png].map { |name| File.join(dir, name) }
      args = ["--project", dir, "--headless", image_path, "--size", "160x100", "--profile", profile_path, "--crash-report", crash_path]
      error = StringIO.new
      assert_equal 0, Canopus::CLI.main(args, output: StringIO.new, error: error), error.string
      report = JSON.parse(File.read(profile_path))
      assert_operator report["statistics"]["frames"], :>=, 1
      assert_match(/Software/, report["context"]["renderer"])
      assert_nil report["statistics"]["last_draw_calls"]
      assert File.file?(image_path)
      refute File.exist?(crash_path)
      refute Thread.list.any? { |thread| thread.name == "canopus-profile" }

      replay_path = File.join(dir, "replay.json")
      File.write(replay_path, '[{"type":"unknown"}]')
      assert_equal 1, Canopus::CLI.main(args + ["--replay", replay_path], output: StringIO.new, error: error)
      assert_match(/unknown replay input/, JSON.parse(File.read(crash_path))["exception"]["message"])
      assert_equal 0, JSON.parse(File.read(profile_path))["statistics"]["frames"]
      refute Thread.list.any? { |thread| thread.name == "canopus-profile" }
      assert_equal 0o600, File.stat(profile_path).mode & 0o777 unless Gem.win_platform?
    end
  end

  def test_cli_rejects_report_overwriting_input
    Dir.mktmpdir do |dir|
      path = File.join(dir, "source.rb")
      File.write(path, "puts :keep")
      error = StringIO.new
      assert_equal 1, Canopus::CLI.main(["--project", dir, "--crash-report", path, "source.rb"], output: StringIO.new, error: error)
      assert_includes error.string, "overlaps"
      assert_equal "puts :keep", File.read(path)
    end
  end

  def test_original_render_exception_survives_cleanup_error_and_tracing_stops
    Dir.mktmpdir do |dir|
      workspace = Canopus::Workspace.new(root: dir)
      window = Zaniah::Platform.open_window(backend: :headless, width: 160, height: 100)
      window.define_singleton_method(:render) { |*| raise "primary render failure" }
      workspace.singleton_class.prepend(Module.new do
        def close
          super
          raise "secondary cleanup failure"
        end
      end)
      error = StringIO.new
      args = ["--project", dir, "--headless", File.join(dir, "out.png"), "--profile", File.join(dir, "profile.json"),
        "--trace-allocations", "--crash-report", File.join(dir, "crash.json")]
      require "objspace"
      stop_trace = ObjectSpace.method(:trace_object_allocations_stop)
      stops = 0
      ObjectSpace.stub(:trace_object_allocations_stop, -> { stops += 1; stop_trace.call }) do
        Canopus::Workspace.stub(:new, ->(*) { workspace }) do
          Zaniah::Platform.stub(:open_window, window) do
            assert_equal 1, Canopus::CLI.main(args, output: StringIO.new, error: error)
          end
        end
      end
      assert window.closed?
      assert_includes error.string, "secondary cleanup failure"
      assert_includes error.string, "primary render failure"
      assert_equal 1, stops
      assert_equal "primary render failure", JSON.parse(File.read(File.join(dir, "crash.json")))["exception"]["message"]
      assert_equal false, JSON.parse(File.read(File.join(dir, "profile.json")))["frames"].first["completed"]
      refute Thread.list.any? { |thread| thread.name == "canopus-profile" }
    end
  end

  def test_existing_allocation_trace_is_not_stopped_by_profile
    require "objspace"
    ObjectSpace.trace_object_allocations_start
    profile = Canopus::PerformanceRecorder.new(Window.new, trace_allocations: true).start
    profile.stop
    assert ObjectSpace.allocation_sourcefile(Object.new)
  ensure
    profile&.stop
    ObjectSpace.trace_object_allocations_stop
  end
end
