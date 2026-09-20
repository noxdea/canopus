# frozen_string_literal: true

require "fileutils"
require "stringio"
require "canopus"
require "wezen"

output = StringIO.new
window = Zaniah::Platform.open_window(backend: :tui, width: 800, height: 600,
  input: StringIO.new, output: output)
workspace = Canopus::Workspace.new(root: Dir.pwd)
controller = Canopus::Controller.new(workspace, window)
begin
events = [Wezen::Cast::Event.new(0.0, :resize, "100x30")]
offset = 0
capture = lambda do |time|
  delta = output.string.byteslice(offset..)
  events << Wezen::Cast::Event.new(time, :output, delta) if delta && !delta.empty?
  offset = output.string.bytesize
end

workspace.editor.insert_text("# Canopus TUI\n\nRun the deterministic demo.\n", auto_indent: false)
controller.tick
capture.call(0.2)
controller.key("ctrl-f")
controller.tick
capture.call(1.0)
controller.key("esc")
controller.tick
capture.call(2.0)
workspace.editor.insert_text("Ready.\n", auto_indent: false)
controller.tick
capture.call(3.0)
events << Wezen::Cast::Event.new(10.0, :output, "")
FileUtils.mkdir_p("docs/media")
Wezen::Cast.write("docs/media/terminal.cast", width: 100, height: 30, title: "Canopus terminal", events: events,
  env: {TERM: "xterm-256color", SHELL: "demo"})
ensure
  workspace&.close
  window&.on_close { true }
  window&.close
end
