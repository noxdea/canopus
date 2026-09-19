# frozen_string_literal: true

require "fileutils"
require "wezen"
require "zaniah"

FileUtils.mkdir_p("docs/media")
png_path = "docs/media/overview.png"
FileUtils.cp("assets/canopus-editor.png", png_path)

width, height, rgba = Zaniah::PNG.decode(File.binread(png_path))
animation = Wezen::Animation.new(width: width, height: height).add(rgba, delay_ms: 1_000)
Wezen::APNG.write("docs/media/overview.apng", animation)
