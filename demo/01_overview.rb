# frozen_string_literal: true

require "fileutils"
require "stringio"
require "canopus"
require "canopus/cli"
require "wezen"
require "zaniah"

FileUtils.mkdir_p("docs/media")
png_path = "docs/media/overview.png"
status = Canopus::CLI.main(["--headless", png_path, "README.md"], output: StringIO.new, error: $stderr)
raise "Canopus headless demo failed (#{status})" unless status.zero?

width, height, rgba = Zaniah::PNG.decode(File.binread(png_path))
animation = Wezen::Animation.new(width: width, height: height).add(rgba, delay_ms: 1_000)
Wezen::APNG.write("docs/media/overview.apng", animation)
