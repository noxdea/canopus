# frozen_string_literal: true

# Runs against released gems, without sibling load paths.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "canopus"
require "canopus/cli"
require "tmpdir"

Dir.mktmpdir("canopus-native-") do |directory|
  File.write(File.join(directory, "example.rb"), "# Native editor test\nputs :hello\n")
  workspace = Canopus::Workspace.new(root: directory)
  workspace.open("example.rb")
  platform = RUBY_PLATFORM.include?("darwin") ? :mac : RUBY_PLATFORM.match?(/mingw|mswin/) ? :windows : :linux
  window = Zaniah::Platform.open_window(backend: platform, width: 640, height: 400, title: "Canopus integration check")
  window.text_system = Zaniah::TextSystem::Renderer.new
  controller = Canopus::Controller.new(workspace, window)
  workspace.start_watching
  controller.tick
  if platform == :linux && window.is_a?(Zaniah::Platform::Linux::Window)
    sender = Process.spawn("xdotool", "windowfocus", window.handle.to_s, "key", "z")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until workspace.editor.buffer.text.start_with?("z")
      raise "native keyboard input did not reach the editor" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      controller.tick
      sleep 0.01
    end
    Process.wait(sender)
  end
  workspace.split(:horizontal)
  # Idle/PNG checks start only after visible background work has settled.
  Canopus.send(:settle_export, controller, window)
  raise "split panes not rendered" unless controller.view.editor_bounds.length == 2
  output = ARGV.find { |argument| argument.end_with?(".png") }
  window.write_png(output) if output
  raise "native GPU draw missing" unless window.device.draw_calls.positive?
  puts "#{window.class}: split editor rendered with #{window.device.draw_calls} GPU draws"
  if ARGV.include?("--idle")
    previous_tick = window.instance_variable_get(:@on_tick)
    warmup = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    deadline = warmup + 5
    start_time = cpu = elapsed = percent = nil
    frames = inputs = 0
    previous_draw = window.instance_variable_get(:@draw)
    previous_input = window.instance_variable_get(:@on_input)
    window.draw { |surface| frames += 1 if start_time; previous_draw.call(surface) }
    window.on_input { |event| inputs += 1 if start_time; previous_input.call(event) }
    window.on_close { true }
    window.on_tick do
      previous_tick&.call
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if !start_time && now >= warmup
        start_time, cpu = now, Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      elsif now >= deadline
        elapsed = now - start_time
        percent = (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu) / elapsed * 100
        window.close
      end
    end
    window.run
    puts "#{inputs.zero? ? 'Idle' : 'Input-contaminated'} editor CPU: #{percent.round(3)}% of one core over #{elapsed.round(2)}s (watcher enabled; #{frames} frames, #{inputs} input events)"
    raise "idle check received input; repeat without interacting with the test window" if ENV["CANOPUS_IDLE_LIMIT"] && inputs.positive?
    if ENV["CANOPUS_IDLE_LIMIT"] && percent > Float(ENV["CANOPUS_IDLE_LIMIT"])
      raise "idle CPU exceeds CANOPUS_IDLE_LIMIT"
    end
  end
ensure
  workspace&.close
  window&.on_close { true }
  window&.close
end
