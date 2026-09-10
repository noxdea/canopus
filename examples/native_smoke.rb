# frozen_string_literal: true

# Development checkout: sibling gem paths are used only by this example.
root = File.expand_path("../..", __dir__)
%w[denebola zaniah alhena kochab spica antares canopus].each do |name|
  $LOAD_PATH.unshift(File.join(root, name, "lib"))
end
require "canopus"

workspace = Canopus::Workspace.new(root: File.expand_path("..", __dir__))
workspace.open("lib/canopus.rb")
window = Zaniah::Platform.open_window(backend: :mac, gpu: ARGV.include?("--gl") ? :opengl : :metal, width: 800, height: 500, title: "Canopus native integration")
window.text_system = Zaniah::TextSystem::Renderer.new
controller = Canopus::Controller.new(workspace, window)
controller.tick
workspace.split(:horizontal)
controller.tick
path = ARGV.find { |arg| arg.end_with?(".png") } || File.join(Dir.tmpdir, "canopus-native.png")
window.write_png(path)
raise "native scene was not submitted" unless window.device.draw_calls.positive?
raise "split editor not rendered" unless controller.view.editor_bounds.length == 2
puts "#{window.device.class}: #{window.device.draw_calls} draws, #{path}"
workspace.close
window.on_close { true }
window.close
