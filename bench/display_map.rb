# frozen_string_literal: true

require "json"
require "objspace"
require_relative "../lib/canopus"

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def milliseconds
  started = now
  yield
  (now - started) * 1000
end

def complete(mapping)
  samples, started = [], now
  while mapping.pending?
    changed = false
    duration = milliseconds { changed = mapping.poll(max_lines: 256) }
    samples << duration if changed
    raise "background layout exceeded 120 seconds" if now - started > 120
    Thread.pass
  end
  samples.sort!
  {wall_ms: ((now - started) * 1000).round(3), polls: samples.size,
    poll_median_ms: samples[samples.size / 2]&.round(3), poll_p95_ms: samples[[(samples.size * 0.95).floor, samples.size - 1].min]&.round(3)}
end

sizes = ARGV.empty? ? [1, 10] : ARGV.map { |argument| Integer(argument) }
sizes.each do |size|
  line = "value = 日本語\t" + "x" * 80 + "\n"
  source = line * ((size * (1 << 20)).fdiv(line.bytesize).ceil)
  buffer = Canopus::Buffer.new(source)
  GC.start
  before = ObjectSpace.memsize_of_all
  mapping = nil
  initial_ms = milliseconds { mapping = Canopus::DisplayMap.new(buffer, wrap_width: 80) }
  provisional_ms = milliseconds { 40.times { |row| mapping.row(row) } }
  initial = complete(mapping)
  GC.start
  retained = ObjectSpace.memsize_of_all - before
  packed_bytes = mapping.tree.sum { |entry| entry.rows.sum { |row| row.text.bytesize + row.offsets.length * 8 } }
  resize_ms = milliseconds { mapping.wrap_width = 60 }
  resized = complete(mapping)
  edited_row = buffer.line_count / 2
  edit_ms = milliseconds { buffer.edit([[buffer.rope.line_start(edited_row)...buffer.rope.line_start(edited_row), "x"]]) }
  edited = complete(mapping)
  close_ms = milliseconds { mapping.dispose }
  puts JSON.generate(bytes: buffer.rope.bytesize, source_rows: buffer.line_count, initial_map_ms: initial_ms.round(3),
    provisional_40_rows_ms: provisional_ms.round(3), initial: initial, retained_bytes: retained, packed_layout_bytes: packed_bytes,
    width_change_ms: resize_ms.round(3), resized: resized, single_row_edit_ms: edit_ms.round(3), edited: edited, dispose_ms: close_ms.round(3))
end
