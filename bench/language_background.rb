# frozen_string_literal: true

require "json"
require_relative "../lib/canopus"

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def measure
  started = now
  yield
  (now - started) * 1000
end

def settle(document)
  samples, started = [], now
  while document.pending?
    samples << measure { document.poll }
    raise "language benchmark exceeded 10 seconds" if now - started > 10
    sleep 0.001
  end
  samples.sort!
  {ready_ms: ((now - started) * 1000).round(3), polls: samples.length,
    poll_median_ms: samples[samples.length / 2].round(3),
    poll_p95_ms: samples[[(samples.length * 0.95).floor, samples.length - 1].min].round(3),
    poll_max_ms: samples.last.round(3)}
end

(ARGV.empty? ? [0.1, 1, 2, 11] : ARGV.map { |value| Float(value) }).each do |size|
  line = "value = \"日本語\" # source line\n"
  source = line * ((size * (1 << 20)).fdiv(line.bytesize).floor)
  buffer = Canopus::Buffer.new(source, path: "example.rb")
  document = Canopus::Language::Document.new(buffer)
  begin
    first = buffer.line_count / 2
    rows = first...(first + 40)
    provisional_ms = measure { rows.each { |row| document.tokens_for(row) }; document.request(syntax: true) }
    initial = settle(document)
    allocations = GC.stat(:total_allocated_objects)
    cached_ms = Array.new(100) { measure { rows.each { |row| document.tokens_for(row) } } }.sort
    allocations = GC.stat(:total_allocated_objects) - allocations
    edit_ms = measure { buffer.edit([[buffer.rope.line_start(first)...buffer.rope.line_start(first), "# "]]) }
    after_edit_ms = measure { rows.each { |row| document.tokens_for(row) } }
    edited = settle(document)
    complete = document.syntax_complete?
    dispose_ms = measure { document.dispose }
    puts JSON.generate(bytes: buffer.rope.bytesize, source_rows: buffer.line_count,
      provisional_40_rows_ms: provisional_ms.round(3), initial: initial,
      cached_40_rows_median_ms: cached_ms[50].round(3), cached_40_rows_p95_ms: cached_ms[95].round(3),
      cached_40_rows_objects: (allocations / 100.0).round(1), edit_ms: edit_ms.round(3),
      after_edit_40_rows_ms: after_edit_ms.round(3), edited: edited, syntax_complete: complete,
      dispose_ms: dispose_ms.round(3))
  ensure
    document.dispose
  end
end
