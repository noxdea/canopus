# frozen_string_literal: true

require "rbconfig"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
require "canopus"
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
target = Float(ENV.fetch("CANOPUS_REQUIRE_TARGET", "0.3"))
abort "canopus require exceeded #{target}s: #{elapsed}s" if ENV["BUDGET"] == "1" && elapsed > target
puts "canopus require: #{format("%.3f", elapsed * 1000)} ms (target #{format("%.0f", target * 1000)} ms, #{RbConfig::CONFIG.fetch("ruby_version")})"
