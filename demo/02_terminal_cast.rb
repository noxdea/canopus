# frozen_string_literal: true

require "fileutils"
require "wezen"

events = [
  Wezen::Cast::Event.new(0.0, :resize, "100x30"),
  Wezen::Cast::Event.new(0.2, :output, "\e[2J\e[HCanopus terminal\r\n"),
  Wezen::Cast::Event.new(0.8, :output, "\e[32m$\e[0m bundle exec rake test\r\n"),
  Wezen::Cast::Event.new(1.2, :output, "\e[90mRunning deterministic checks...\e[0m\r\n"),
  Wezen::Cast::Event.new(2.0, :output, "\e[32mPASS\e[0m  128 tests, 0 failures\r\n"),
  Wezen::Cast::Event.new(2.4, :output, "\r\n\e[36mready\e[0m _"),
  Wezen::Cast::Event.new(10.0, :output, "\r\n")
]
FileUtils.mkdir_p("docs/media")
Wezen::Cast.write("docs/media/terminal.cast", width: 100, height: 30, title: "Canopus terminal", events: events,
  env: {TERM: "xterm-256color", SHELL: "demo"})
