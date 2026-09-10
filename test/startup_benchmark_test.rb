# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require_relative "../bench/startup"

class StartupBenchmarkTest < Minitest::Test
  SCRIPT = File.expand_path("../bench/startup.rb", __dir__)

  def invoke(*options)
    Open3.capture3({"RUBYOPT" => nil, "RUBYLIB" => nil, "CANOPUS_STARTUP_BENCH" => nil},
      RbConfig.ruby, SCRIPT, "--headless", "--runs", "1", "--size", "160x100", *options)
  end

  def test_actual_cli_edit_and_render_with_and_without_automatic_rubygems
    [[], ["--disable-gems"]].each do |flags|
      output, error, status = invoke(*flags)
      assert status.success?, error
      report = JSON.parse(output)
      sample = report.fetch("samples").fetch(0)
      assert_equal "exe/canopus", report.fetch("entrypoint")
      assert sample.fetch("edited")
      assert_equal 1, sample.fetch("completed_renders")
      assert_equal "Zaniah::GPU::Software", sample.fetch("backend")
      assert_equal [160, 100], sample.fetch("viewport")
      assert sample.fetch("rubygems")
      assert sample.fetch("yjit") if !RUBY_PLATFORM.match?(/mswin|mingw/) && RbConfig::CONFIG["YJIT_SUPPORT"] == "yes"
      assert_operator sample.fetch("seconds"), :>, 0
      assert_nil report.fetch("native_target_passed"), "headless timing cannot pass a native gate"
    end
  end

  def test_child_timeout_is_bounded_and_reported_as_failure
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, error, status = invoke("--timeout", "0.001")
    refute status.success?
    assert_empty output
    assert_includes error, "startup timed out"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_stopping_child_also_closes_descendant_output_and_working_directory
    pid = descendant = nil
    child = <<~'RUBY'
      require "json"
      require "rbconfig"
      STDOUT.binmode
      STDOUT.sync = true
      descendant = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
      puts "CANOPUS_STARTUP_READY " + JSON.generate(descendant: descendant)
      sleep 30
    RUBY
    reader, writer = IO.pipe
    Dir.mktmpdir("canopus-startup-tree-") do |directory|
      spawn_options = {out: writer, err: File::NULL, in: File::NULL, chdir: directory}
      spawn_options[RUBY_PLATFORM.match?(/mswin|mingw/) ? :new_pgroup : :pgroup] = true
      pid = Process.spawn(RbConfig.ruby, "-e", child, **spawn_options)
      writer.close
      report, = CanopusStartupBenchmark.wait_for_report(reader, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
      descendant = report.fetch("descendant")
      CanopusStartupBenchmark.stop_child(pid)
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      pid = nil
      assert IO.select([reader], nil, nil, 2), "descendant kept the output pipe open"
      assert_nil reader.read(1)
      descendant = nil
    ensure
      begin
        CanopusStartupBenchmark.stop_child(pid) if pid
        Process.kill("KILL", descendant) if descendant
      rescue Errno::ESRCH
        nil
      end
    end
  ensure
    [reader, writer].compact.each { |io| io.close unless io.closed? }
  end

  def test_windows_stop_uses_the_pid_tree_and_reaps_both_commands
    calls = []
    CanopusStartupBenchmark.const_set(:RUBY_PLATFORM, "x64-mingw-ucrt")
    spawn = ->(*arguments, **options) { calls << [:spawn, arguments, options]; 5678 }
    wait = ->(pid, _deadline) { calls << [:wait, pid] }
    Process.stub(:spawn, spawn) do
      CanopusStartupBenchmark.stub(:wait_for_exit, wait) { CanopusStartupBenchmark.stop_child(1234) }
    end
    assert_equal [:spawn, ["taskkill", "/PID", "1234", "/T", "/F"], {out: File::NULL, err: File::NULL}], calls.first
    assert_equal [[:wait, 5678], [:wait, 1234]], calls.drop(1)
  ensure
    CanopusStartupBenchmark.send(:remove_const, :RUBY_PLATFORM)
  end
end
