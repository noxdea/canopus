# frozen_string_literal: true

# Profile the app's real Element render path using its runtime gems.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "canopus"
require "canopus/performance_recorder"
require "optparse"
require "tmpdir"

options = {frames: 120, output: "canopus-frames.json", diagnostics: true}
OptionParser.new do |parser|
  parser.on("--frames COUNT", Integer) { |value| options[:frames] = value }
  parser.on("--output JSON") { |value| options[:output] = value }
  parser.on("--headless") { options[:headless] = true }
  parser.on("--no-diagnostics", "Measure without the overlay or stack sampler") { options[:diagnostics] = false }
  parser.on("--max-ms NUMBER", Float) { |value| options[:max_ms] = value }
  parser.on("--max-allocations COUNT", Integer) { |value| options[:max_allocations] = value }
end.parse!
raise ArgumentError, "frames must be between 1 and 600" unless options[:frames].between?(1, 600)
Canopus::PerformanceRecorder.validate_paths([options[:output]])

Dir.mktmpdir("canopus-profile-") do |directory|
  File.write(File.join(directory, "example.rb"), "# Whole-editor frame check\n" + (1..100).map { |i| "value_#{i} = #{i}\n" }.join)
  workspace = Canopus::Workspace.new(root: directory)
  workspace.open("example.rb")
  platform = options[:headless] ? :headless : RUBY_PLATFORM.include?("darwin") ? :mac : Gem.win_platform? ? :windows : :linux
  window = Zaniah::Platform.open_window(backend: platform, width: 640, height: 400, title: "Canopus frame profile")
  window.text_system = Zaniah::TextSystem::Renderer.new
  controller = Canopus::Controller.new(workspace, window)
  3.times { window.request_frame; controller.tick }
  performance = Canopus::PerformanceRecorder.new(window, sampling: options[:diagnostics]).start
  workspace.performance = performance if options[:diagnostics]
  input_times = []
  options[:frames].times do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    controller.input(Zaniah::Input::TextInput.new("a"))
    controller.tick
    input_times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  end
  performance.stop
  ordered = input_times.sort
  report = performance.report.merge(benchmark: {warmup_frames: 3, measured_frames: options[:frames],
    diagnostics: options[:diagnostics], input: "single-character insertion before each render",
    input_to_present: {boundary: "Controller#input plus tick/render/present return; excludes physical keyboard, OS input queue and asynchronous GPU/display completion",
      milliseconds: input_times, median_ms: (ordered[(ordered.length - 1) / 2] + ordered[ordered.length / 2]) / 2,
      p95_ms: ordered[(ordered.length * 0.95).ceil - 1]}})
  Canopus::PerformanceRecorder.write_json(options[:output], report)
  stats = performance.statistics
  puts "#{window.device.class}: #{stats[:frames]} frames, median #{stats[:median_frame_ms].round(3)} ms, mean #{stats[:mean_allocations].round(1)} Ruby objects; #{options[:output]}"
  puts "Input dispatch to present return: median #{report[:benchmark][:input_to_present][:median_ms].round(3)} ms (not physical key-to-screen latency)"
  raise "median frame time exceeds --max-ms" if options[:max_ms] && stats[:median_frame_ms] > options[:max_ms]
  raise "mean frame allocations exceed --max-allocations" if options[:max_allocations] && stats[:mean_allocations] > options[:max_allocations]
ensure
  performance&.stop
  workspace&.close
  window&.on_close { true }
  window&.close
end
