# frozen_string_literal: true

require "json"
require "optparse"
require "rbconfig"
require "tmpdir"

module CanopusStartupBenchmark
  SOURCE = "# Startup benchmark\nputs :hello\n"
  EDIT = "x"
  READY = "CANOPUS_STARTUP_READY "
  CLOCK = Process::CLOCK_MONOTONIC
  class Failure < StandardError; end

  # Loaded by RUBYOPT, including the launcher's normal YJIT re-exec. Observe
  # the real Controller only after Ruby has loaded its complete definition.
  def self.install_probe
    trace = TracePoint.new(:end) do |event|
      next unless event.self.name == "Canopus::Controller"
      trace.disable
      event.self.prepend(ControllerProbe)
    end
    trace.enable
  end

  module ControllerProbe
    def initialize(workspace, window)
      super
      probe = self
      window.singleton_class.prepend(Module.new do
        define_method(:render) do |*args, **kwargs, &block|
          result = super(*args, **kwargs, &block)
          probe.startup_render_completed
          result
        end
      end)
    end

    def input(event)
      result = super
      if event.is_a?(Zaniah::Input::TextInput) && event.text == EDIT
        @startup_edited = workspace.editor.buffer.text == EDIT + SOURCE
        raise Failure, "CLI replay did not edit the selected buffer" unless @startup_edited
      end
      result
    end

    def startup_render_completed
      @startup_frames = (@startup_frames || 0) + 1
      return unless @startup_edited && !@startup_reported
      @startup_reported = true
      report = {ruby: RUBY_DESCRIPTION, yjit: !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?),
        zjit: !!(defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?), rubygems: !!defined?(Gem),
        window: window.class.name, backend: window.device.class.name,
        viewport: [window.content_size.width, window.content_size.height], scale_factor: window.scale_factor,
        draw_calls: window.device.respond_to?(:draw_calls) ? window.device.draw_calls : nil,
        edited: true, completed_renders: @startup_frames}
      $stdout.puts(READY + JSON.generate(report))
      $stdout.flush
      # Headless CLI still finishes its ordinary settled PNG export. Native
      # windows close through the normal CLI ensure, discarding only this fixture.
      unless window.instance_of?(Zaniah::Platform::Headless::Window)
        window.on_close { true }
        window.close
      end
    end
  end

  def self.wait_for_report(reader, deadline)
    buffer = +""
    loop do
      remaining = deadline - Process.clock_gettime(CLOCK)
      raise Failure, "startup timed out before completed edit/render" unless remaining.positive? && IO.select([reader], nil, nil, remaining)
      buffer << reader.readpartial(4096)
      raise Failure, "unexpectedly large child output" if buffer.bytesize > 65_536
      while (ending = buffer.index("\n"))
        line = buffer.slice!(0, ending + 1)
        next unless line.start_with?(READY)
        finished = Process.clock_gettime(CLOCK)
        return [JSON.parse(line.delete_prefix(READY)), finished]
      end
    end
  rescue EOFError
    raise Failure, "CLI exited before completed edit/render"
  end

  def self.wait_for_exit(pid, deadline)
    loop do
      result = Process.waitpid2(pid, Process::WNOHANG)
      return result.last if result
      raise Failure, "CLI cleanup timed out" if Process.clock_gettime(CLOCK) >= deadline
      sleep 0.01
    end
  end

  def self.stop_child(pid)
    return unless pid
    if RUBY_PLATFORM.match?(/mswin|mingw/)
      # Killing only Ruby leaves process-pool descendants holding the fixture
      # directory open. Finish the complete tree before mktmpdir removes it.
      killer = Process.spawn("taskkill", "/PID", pid.to_s, "/T", "/F", out: File::NULL, err: File::NULL)
      begin
        wait_for_exit(killer, Process.clock_gettime(CLOCK) + 2)
      rescue Failure
        Process.kill("KILL", killer)
        Process.waitpid(killer)
        raise
      end
      wait_for_exit(pid, Process.clock_gettime(CLOCK) + 2)
      return
    end
    target = -pid
    ["TERM", "KILL"].each do |signal|
      return if Process.waitpid(pid, Process::WNOHANG)
      Process.kill(signal, target)
      begin
        wait_for_exit(pid, Process.clock_gettime(CLOCK) + 2)
        return
      rescue Failure
        next
      end
    end
    warn "startup benchmark: child #{pid} did not exit after KILL"
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def self.sample(options)
    Dir.mktmpdir("canopus-startup-") do |directory|
      project = File.join(directory, "project")
      Dir.mkdir(project)
      source = File.join(project, "example.rb")
      File.binwrite(source, SOURCE)
      replay = File.join(directory, "replay.json")
      File.write(replay, JSON.generate([{type: "text", text: EDIT}]))
      command = [RbConfig.ruby]
      command << "--disable-gems" if options[:disable_gems]
      command.concat([File.expand_path("../exe/canopus", __dir__), "--project", project, "--replay", replay])
      command.concat(["--headless", File.join(directory, "frame.png")]) if options[:headless]
      command.concat(["--size", options[:size]]) if options[:size]
      command << source
      env = {"CANOPUS_STARTUP_BENCH" => "1", "CANOPUS_YJIT_REEXEC" => nil,
        "RUBYOPT" => "-rstartup", "RUBYLIB" => __dir__, "XDG_CONFIG_HOME" => File.join(directory, "config")}
      reader, writer = IO.pipe
      errors = File.open(File.join(directory, "stderr.log"), "w+")
      spawn_options = {out: writer, err: errors, in: File::NULL, chdir: project, close_others: true}
      spawn_options[RUBY_PLATFORM.match?(/mswin|mingw/) ? :new_pgroup : :pgroup] = true
      started = Process.clock_gettime(CLOCK)
      pid = Process.spawn(env, *command, **spawn_options)
      writer.close
      report, finished = wait_for_report(reader, started + options[:timeout])
      status = wait_for_exit(pid, started + options[:timeout])
      pid = nil
      raise Failure, "CLI exited unsuccessfully (#{status.exitstatus})" unless status.success?
      raise Failure, "fixture was unexpectedly saved" unless File.binread(source) == SOURCE
      report.merge("seconds" => finished - started)
    rescue Failure => error
      errors&.flush
      errors&.rewind
      raise Failure, "#{error.message}\n#{errors&.read(8192)}".strip
    ensure
      begin
        stop_child(pid)
      ensure
        [reader, writer, errors].compact.each { |io| io.close unless io.closed? }
      end
    end
  end

  def self.main(argv)
    options = {runs: 3, timeout: 30.0}
    OptionParser.new do |parser|
      parser.on("--headless", "CI software-rendering smoke, not a native timing gate") { options[:headless] = true }
      parser.on("--runs COUNT", Integer) { |value| options[:runs] = value }
      parser.on("--timeout SECONDS", Float) { |value| options[:timeout] = value }
      parser.on("--size WIDTHxHEIGHT", /\A\d+x\d+\z/) { |value| options[:size] = value }
      parser.on("--disable-gems", "Start the child without automatic RubyGems loading") { options[:disable_gems] = true }
    end.parse!(argv)
    raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise ArgumentError, "runs must be between 1 and 20" unless options[:runs].between?(1, 20)
    raise ArgumentError, "timeout must be positive and at most 120 seconds" unless options[:timeout].finite? && options[:timeout].positive? && options[:timeout] <= 120
    samples = Array.new(options[:runs]) { sample(options) }
    seconds = samples.map { |sample| sample.fetch("seconds") }.sort
    native = !options[:headless] && samples.none? { |sample| sample.fetch("backend") == "Zaniah::GPU::Software" }
    puts JSON.pretty_generate(kind: "startup", entrypoint: "exe/canopus", samples: samples,
      measurement: "Parent spawn through CLI replay edit and first completed Window#render/present return notification; includes hook/IPC overhead, excludes shutdown/PNG export, physical keyboard/OS input queue and asynchronous GPU/display completion",
      caches: "Fresh Ruby process and temporary project per sample; OS filesystem/font/shader caches are not flushed",
      settings: "Default settings in an isolated temporary XDG_CONFIG_HOME; no persistent glyph cache",
      median_seconds: (seconds[(seconds.length - 1) / 2] + seconds[seconds.length / 2]) / 2,
      max_seconds: seconds.last, native_target_seconds: 1.5,
      native_target_passed: native ? seconds.all? { |value| value < 1.5 } : nil)
    0
  rescue StandardError => error
    warn "startup benchmark: #{error.message}"
    1
  end
end

if ENV["CANOPUS_STARTUP_BENCH"] == "1"
  CanopusStartupBenchmark.install_probe
elsif $PROGRAM_NAME == __FILE__
  exit CanopusStartupBenchmark.main(ARGV)
end
