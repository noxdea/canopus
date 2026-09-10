# frozen_string_literal: true

require "benchmark"
require "tmpdir"
require "fileutils"
require_relative "../lib/canopus/project"

count = Integer(ARGV.fetch(0, "100000"))
raise ArgumentError, "positive file count required" unless count.positive?
Dir.mktmpdir("canopus-search-bench-") do |directory|
  count.times do |index|
    group = File.join(directory, (index / 1000).to_s)
    Dir.mkdir(group) unless Dir.exist?(group)
    extension = (index % 10).zero? ? "rb" : "txt"
    File.write(File.join(group, "#{index}.#{extension}"), "searchable fixture #{index}\n")
  end
  project = Canopus::Project.new(directory)
  {all: {}, ruby: {extensions: ["rb"]}}.each do |name, filters|
    [1, 4].each do |workers|
      matches = nil
      seconds = Benchmark.realtime { matches = project.search("missing needle", workers: workers, **filters) }
      raise "unexpected match" unless matches.empty?
      puts "#{name}: #{count} files, workers=#{workers}, #{seconds.round(3)} s"
    end
  end
end
