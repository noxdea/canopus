# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/canopus"

# One file with separated matches exercises 2 * COUNT source anchors. Pass
# "open" to include rebinding a private snapshot to an existing live buffer.
count = Integer(ARGV.fetch(0, "1000"))
raise ArgumentError, "count must be 1..10000" unless (1..10_000).cover?(count)
Dir.mktmpdir("canopus-search-preparation-") do |directory|
  File.write(File.join(directory, "results.txt"), "target\npadding\npadding\npadding\n" * count)
  workspace = Canopus::Workspace.new(root: directory)
  workspace.new_buffer
  workspace.open("results.txt") if ARGV[1] == "open"
  callbacks = []
  workspace.define_singleton_method(:post) do |&work|
    super() do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      work.call
      callbacks << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  workspace.search_project("target")
  loop do
    workspace.instance_variable_get(:@search_job)&.join
    workspace.drain
    break if workspace.editor.buffer.is_a?(Canopus::MultiBuffer)
    raise workspace.message unless workspace.message.include?("Searching")
  end
  puts JSON.generate(matches: count, open_source: ARGV[1] == "open",
    excerpts: workspace.editor.buffer.excerpts.length, foreground_ms: callbacks,
    total_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
ensure
  workspace&.close
end
