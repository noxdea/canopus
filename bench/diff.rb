# frozen_string_literal: true
require_relative "../lib/canopus"
require "diff/lcs"
require "timeout"

cases = {}
left = Array.new(20_000) { |i| "line #{i}\n" }
right = left.dup
right[10_000] = "changed\n"
cases["20k unique / one edit"] = [left, right]
left = Array.new(20_000) { |i| "statement #{i % 10}\n" }
right = left.dup
20.times { |i| right[i * 1000 + 10] = "change #{i}\n" }
cases["20k repeated / distant edits"] = [left, right]
cases.each do |name, (before, after)|
  {"diff-lcs" => -> { Diff::LCS.sdiff(before, after) }, "Myers" => -> { Canopus::Git::Diff.edits(before, after) }}.each do |engine, operation|
    samples = Array.new(3) do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Timeout.timeout(5) { operation.call }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end
    puts "#{name}: #{engine} median #{samples.sort[1].round(3)} ms"
  rescue Timeout::Error
    puts "#{name}: #{engine} exceeded 5 seconds"
  end
end
