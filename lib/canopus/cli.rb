# frozen_string_literal: true

require "optparse"
require "json"

module Canopus
  module CLI
    def self.main(argv = ARGV, output: $stdout, error: $stderr)
      options = {width: 1100, height: 760, root: Dir.pwd, platform: nil, gpu: nil, plugins: [], grants: []}
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: canopus [options] [files...]"
        flags.on("--project DIRECTORY", "Project root") { |value| options[:root] = value }
        flags.on("--headless PNG", "Render to a PNG without opening a window") { |value| options[:png] = value; options[:platform] = :headless }
        flags.on("--tui", "Run in the current terminal") { options[:platform] = :tui }
        flags.on("--backend BACKEND", %w[metal opengl], "GPU backend") { |value| options[:gpu] = value.to_sym }
        flags.on("--size WIDTHxHEIGHT", /\A\d+x\d+\z/, "Window dimensions") { |value| options[:width], options[:height] = value.split("x").map(&:to_i) }
        flags.on("--settings JSONC", "Settings file") { |value| options[:settings] = value }
        flags.on("--session JSON", "Restore and save a workspace session") { |value| options[:session] = value }
        flags.on("--replay JSON", "Replay text, key, and action input records") { |value| options[:replay] = value }
        flags.on("--glyph-cache DIRECTORY", "Reuse a checksummed glyph atlas in this directory") { |value| options[:glyph_cache] = value }
        flags.on("--profile JSON_PATH", "Save frame timings and sampled Ruby stacks on exit") { |value| options[:profile] = value }
        flags.on("--trace-allocations", "Trace live allocation sites (slow; requires --profile)") { options[:trace_allocations] = true }
        flags.on("--crash-report JSON_PATH", "Save exceptions locally; review before sharing") { |value| options[:crash_report] = value }
        flags.on("--vim", "Enable Vim keybindings") { options[:vim] = true }
        flags.on("--plugin RUBY", "Load a Ruby plugin (requires --trust-plugins)") { |value| options[:plugins] << value }
        flags.on("--trust-plugins", "Allow the selected plugins to execute trusted Ruby code") { options[:trust_plugins] = true }
        flags.on("--grant PERMISSION", Plugins::Registry::PERMISSIONS, "Grant a plugin API permission (repeatable)") { |value| options[:grants] << value }
        flags.on("--plugins-in-process", "Run trusted plugins in the editor process") { options[:plugins_in_process] = true }
        flags.on("--version") { output.puts(VERSION); return 0 }
        flags.on("--help") { output.puts(flags); return 0 }
      end
      files = parser.parse(argv.dup)
      validate_cli_options(options, files)
      run_cli(options, files, output: output, error: error)
    rescue OptionParser::ParseError, StandardError => exception
      error.puts("canopus: #{exception.message}")
      1
    end

    def self.validate_cli_options(options, files)
      unless options.values_at(:width, :height).all? { |value| value.between?(100, 16_384) }
        raise ArgumentError, "window dimensions must be between 100 and 16384"
      end
      raise ArgumentError, "--trace-allocations requires --profile" if options[:trace_allocations] && !options[:profile]
      if options[:glyph_cache] && File.exist?(options[:glyph_cache]) && !File.directory?(options[:glyph_cache])
        raise ArgumentError, "--glyph-cache must name a directory"
      end
      return unless options[:profile] || options[:crash_report]
      require_relative "performance_recorder"
      protected = files.map { |path| File.expand_path(path, options[:root]) }
      protected.concat(options.values_at(:png, :settings, :session, :replay)).concat(options[:plugins])
      protected << Settings.user_path << File.join(File.expand_path(options[:root]), ".canopus", "settings.jsonc")
      PerformanceRecorder.validate_paths(options.values_at(:profile, :crash_report), protected: protected)
    end
    private_class_method :validate_cli_options

    def self.run_cli(options, files, output:, error:)
      settings = Settings.new(Settings.user_path, File.join(File.expand_path(options[:root]), ".canopus", "settings.jsonc"),
        options[:settings], options[:vim] ? {"vim_mode" => true} : {})
      workspace = Workspace.new(root: options[:root], settings: settings)
      workspace.restore_session(options[:session]) if options[:session] && File.file?(options[:session])
      files.each { |path| workspace.open(path) }
      platform = options[:platform] || (RUBY_PLATFORM.include?("darwin") ? :mac : RUBY_PLATFORM.match?(/mswin|mingw/) ? :windows : :linux)
      window_options = {width: options[:width], height: options[:height], title: "Canopus"}
      window_options[:gpu] = options[:gpu] if options[:gpu] && platform != :headless && platform != :tui
      if platform == :tui
        require "io/console"
        rows, columns = output.winsize if output.respond_to?(:winsize) && output.tty?
        window_options.merge!(width: columns * 8, height: rows * 20) if rows && rows.positive?
        window_options[:output] = output
      end
      window = Zaniah::Platform.open_window(backend: platform, **window_options)
      if options[:profile]
        performance = PerformanceRecorder.new(window, trace_allocations: options[:trace_allocations]).start
        workspace.performance = performance
      end
      controller = Controller.new(workspace, window)
      workspace.configure_text_system(cache_dir: options[:glyph_cache]) unless platform == :tui
      workspace.apply_settings
      warmup = Thread.new { window.text_system.prewarm(size: settings["font_size"]) } unless platform == :tui
      warmup.report_on_exception = false if warmup
      workspace.start_watching unless platform == :headless
      warmup&.value
      GC.compact if GC.respond_to?(:compact)
      options[:plugins].each { |path| workspace.plugins.load(path, trusted: options[:trust_plugins], permissions: options[:grants], isolated: !options[:plugins_in_process]) }
      if options[:replay]
        records = JSON.parse(File.read(options[:replay]))
        raise ArgumentError, "replay must be an array" unless records.is_a?(Array)
        records.each do |record|
          case record.fetch("type")
          when "text" then controller.input(Zaniah::Input::TextInput.new(record.fetch("text")))
          when "key" then controller.input(Zaniah::Input::KeyDown.new(record.fetch("key"), false))
          when "action" then workspace.call(record.fetch("action"))
          else raise ArgumentError, "unknown replay input"
          end
        end
      end
      if options[:png]
        settle_export(controller, window)
        window.write_png(options[:png])
        output.puts(options[:png])
      else
        window.run
      end
      workspace.save_session(options[:session]) if options[:session]
      0
    rescue Exception => exception
      # Fatal Ruby exceptions are re-raised after cleanup/reporting, not swallowed.
      failure = exception
    ensure
      begin
        warmup&.join
      rescue Exception => exception
        failure ||= exception
      end
      failure = finish_cli(options, workspace, window, performance, failure, error: error)
      raise failure if failure
    end
    private_class_method :run_cli

    # Exports need settled colors/wrapping; interactive windows intentionally show
    # provisional content immediately. Do not repaint every background batch.
    def self.settle_export(controller, window, timeout: 30)
      controller.tick
      workspace = controller.workspace
      pending = lambda do
        waiting = false
        workspace.panes.filter_map(&:active).each do |editor|
          error = editor.display_map.layout_error || editor.language_document.analysis_error
          raise Error, "PNG export failed: #{error.message}" if error
          waiting ||= editor.display_map.pending? || editor.language_document.pending?
        end
        waiting
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while pending.call
        while pending.call
          raise Error, "PNG export timed out waiting for background layout or syntax" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          workspace.drain
          controller.poll_display_maps
          controller.poll_language_documents
          sleep 0.002 if pending.call
        end
        window.request_frame
        controller.tick
      end
    end
    private_class_method :settle_export

    def self.finish_cli(options, workspace, window, performance, failure, error:)
      operations = [-> { performance&.stop }, -> { workspace&.close },
        -> { window&.on_close { true }; window&.close },
        -> { performance&.write(options[:profile]) }]
      operations.each do |operation|
        operation.call
      rescue StandardError => exception
        error.puts("canopus: cleanup/report failed: #{exception.message}") if failure
        failure ||= exception
      end
      if failure && options[:crash_report]
        begin
          PerformanceRecorder.write_crash(options[:crash_report], failure, window: window)
        rescue StandardError => exception
          error.puts("canopus: crash report failed: #{exception.message}")
        end
      end
      failure
    end
      private_class_method :finish_cli
  end
end
