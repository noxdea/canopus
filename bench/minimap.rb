# frozen_string_literal: true

require "benchmark"
require "json"
require "tmpdir"
require "canopus"

FRAME_BUDGET_RATIO = 2.5

Dir.mktmpdir("canopus-minimap-") do |directory|
  path = File.join(directory, "large.rb")
  File.write(path, (0...10_000).map { |row| "value_#{row} = 日本語\n" }.join)
  settings = Canopus::Settings.new("minimap" => {"enabled" => false, "width" => 100},
    "breadcrumbs" => {"enabled" => false}, "sticky_scroll" => {"enabled" => false},
    "dock" => {"left" => {"visible" => false}})
  workspace = Canopus::Workspace.new(root: directory, settings: settings)
  editor = workspace.open(path)
  window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 400)
  window.text_system = Zaniah::TextSystem::Renderer.new
  controller = Canopus::Controller.new(workspace, window)

  controller.tick
  baseline = Array.new(20) do
    editor.scroll(dy: 1)
    window.request_frame
    Benchmark.realtime { controller.tick } * 1_000
  end.sort
  baseline_p95 = baseline[(baseline.length * 0.95).ceil - 1]
  settings.merge!("minimap" => {"enabled" => true})
  window.request_frame
  cold_ms = Benchmark.realtime { controller.tick } * 1_000
  cold_generated = workspace.minimap.generated
  frames = 1
  while workspace.minimap.pending?
    raise "minimap did not warm in 32 frames" if frames >= 32
    window.request_frame
    controller.tick
    frames += 1
  end

  warm = Array.new(20) do
    editor.scroll(dy: 1)
    window.request_frame
    Benchmark.realtime { controller.tick } * 1_000
  end.sort
  warm_generated = workspace.minimap.generated
  cached = workspace.minimap.cached_rows(editor.buffer)
  row = cached[cached.length / 2]
  offset = editor.buffer.rope.line_start(row)
  editor.buffer.edit([[offset...offset, "x"]])
  window.request_frame
  edit_ms = Benchmark.realtime { controller.tick } * 1_000
  edit_generated = workspace.minimap.generated

  warm_p95 = warm[(warm.length * 0.95).ceil - 1]
  result = {lines: editor.buffer.line_count, baseline_p95_ms: baseline_p95.round(3), cold_ms: cold_ms.round(3),
    cold_generated: cold_generated, warm_frames: frames, warm_p95_ms: warm_p95.round(3),
    warm_ratio: (warm_p95 / baseline_p95).round(3),
    warm_generated: warm_generated, edit_ms: edit_ms.round(3), edit_generated: edit_generated,
    cached_rows: workspace.minimap.cache_size}
  puts JSON.generate(result)

  if ENV["BUDGET"] == "1"
    raise "cold frame generated too many textures" if cold_generated > Canopus::Minimap::GENERATION_LIMIT
    raise "warm scroll regenerated line textures" unless warm_generated.zero?
    raise "single-line edit did not regenerate exactly one texture" unless edit_generated == 1
    raise "minimap cache exceeded its row bound" if workspace.minimap.cache_size > Canopus::Minimap::ENTRY_LIMIT
    raise "warm scroll exceeded #{FRAME_BUDGET_RATIO}x baseline" if warm_p95 > baseline_p95 * FRAME_BUDGET_RATIO
  end
ensure
  workspace&.close
  window&.on_close { true }
  window&.close
end
