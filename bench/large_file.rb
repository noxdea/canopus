# frozen_string_literal: true

require "tempfile"
require "benchmark"
require "canopus"

Tempfile.create("canopus-100mb-") do |file|
  line = "0123456789" * 9 + " Japanese 日本 text\n"
  chunk = line * 10_000
  file.write(chunk) while file.size < 105 * 1024 * 1024
  file.flush
  buffer = nil
  opening = Benchmark.realtime { buffer = Canopus::Buffer.open(file.path) }
  editor = nil
  display = Benchmark.realtime { editor = Canopus::Editor.new(buffer) }
  random = Random.new(42)
  times = Array.new(1000) do
    row = random.rand(buffer.line_count)
    Benchmark.realtime { buffer.line(row) }
  end.sort
  puts "#{file.size} bytes, #{buffer.line_count} lines"
  puts "open/index: #{(opening * 1000).round(2)} ms; display map: #{(display * 1000).round(2)} ms"
  puts "line access median: #{(times[500] * 1_000_000).round(2)} us; p95: #{(times[950] * 1_000_000).round(2)} us"
  puts "cached pages: #{buffer.rope.cached_bytes} bytes; read only: #{buffer.read_only}"
  raise "line access budget exceeded" if ARGV.include?("--assert-budget") && times[500] > 0.001
  editor.dispose
  buffer.close
end
