# frozen_string_literal: true

require "json"
require "tempfile"
require "time"

module Canopus
  # Installed only for an explicitly profiled window, never on the Window class.
  class PerformanceRecorder
    attr_reader :sampler

    def initialize(window, trace_allocations: false, sampling: true, capacity: 600, sample_capacity: 2_000, interval: 0.01)
      raise ArgumentError, "profile capacities must be positive integers" unless [capacity, sample_capacity].all? { |n| n.is_a?(Integer) && n.positive? }
      raise ArgumentError, "sampling interval must be positive and finite" unless interval.positive? && interval.finite?
      @window, @trace_allocations = window, trace_allocations
      @sampling = sampling
      @capacity, @sample_capacity, @interval = capacity, sample_capacity, interval
      @frames, @stacks = [], []
      @count = @sample_count = @total_allocations = 0
      @max_frame_ms = 0.0
      @mutex, @wake = Mutex.new, ConditionVariable.new
    end

    def start
      raise ArgumentError, "a profile can only be started once" if @started
      @started = true
      if @trace_allocations
        require "objspace"
        ObjectSpace.trace_object_allocations_start
        @tracing = true
      end
      @running = true
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      profile = self
      @window.singleton_class.prepend(Module.new do
        define_method(:render) do |*args, **kwargs, &block|
          profile.measure { super(*args, **kwargs, &block) }
        end
      end)
      if @sampling
        @sampler = Thread.new { sample_main_thread }
        @sampler.name = "canopus-profile"
      end
      self
    rescue Exception
      stop
      raise
    end

    def measure
      return yield unless @running
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      completed = false
      begin
        result = yield
        completed = true
        result
      ensure
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
        allocations = GC.stat(:total_allocated_objects) - allocated
        draws = @window.device.draw_calls if completed && @window.device.respond_to?(:draw_calls)
        @last = {frame: @count + 1, frame_ms: elapsed, allocations: allocations, draw_calls: draws,
          scale_factor: @window.scale_factor, completed: completed}
        @frames[@count % @capacity] = @last
        @count += 1
        @total_allocations += allocations
        @max_frame_ms = [@max_frame_ms, elapsed].max
      end
    end

    def stop
      @mutex.synchronize { @running = false; @wake.broadcast }
      begin
        @sampler&.join
      ensure
        @stopped_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @tracing
          ObjectSpace.trace_object_allocations_stop
          @tracing = false
          @allocation_sites = allocation_sites
        end
      end
      self
    end

    def statistics
      times = @frames.map { |frame| frame[:frame_ms] }.sort
      {frames: @count, retained_frames: @frames.length,
       last_frame_ms: @last&.fetch(:frame_ms), last_allocations: @last&.fetch(:allocations), last_draw_calls: @last&.fetch(:draw_calls),
       median_frame_ms: percentile(times, 0.5), p95_frame_ms: percentile(times, 0.95), max_frame_ms: @max_frame_ms,
       mean_allocations: @count.zero? ? 0 : @total_allocations.fdiv(@count), sampling_samples: @sample_count}
    end

    def report
      raise ArgumentError, "stop the profile before saving it" if @running
      {schema_version: 1, kind: "profile", generated_at: Time.now.utc.iso8601,
       context: self.class.context(@window), elapsed_seconds: @started_at ? @stopped_at - @started_at : 0,
       measurement: {
         frame: "Window#render: UI construction, layout, prepaint, paint, GPU submission and synchronous presentation; excludes input/tick/draw callbacks and asynchronous GPU completion",
         allocations: "Process-wide GC total_allocated_objects delta during render, including other threads and sampling overhead; excludes frame-record bookkeeping",
         percentiles: "Retained frame window only; max and mean allocations cover all observed frames",
         timing: "Wall clock, including GC, scheduler waits and synchronous native calls; not GPU timestamps or idle CPU",
         trace_allocations: @trace_allocations
       }, statistics: statistics, frames: @frames.sort_by { |frame| frame[:frame] },
       sampling: {enabled: @sampling, interval_seconds: @interval, max_depth: 32, total_samples: @sample_count, retained_samples: @stacks.length,
         stacks: @stacks.tally.map { |stack, count| {count: count, stack: stack} }.sort_by { |entry| -entry[:count] }},
       allocation_sites: @allocation_sites}
    end

    def write(path) = self.class.write_json(path, report)

    private

    def percentile(sorted, fraction)
      return 0.0 if sorted.empty?
      index = (sorted.length - 1) * fraction
      sorted[index.floor] + (sorted[index.ceil] - sorted[index.floor]) * (index - index.floor)
    end

    def sample_main_thread
      loop do
        running = @mutex.synchronize do
          @wake.wait(@mutex, @interval) if @running
          @running
        end
        break unless running
        # These are Ruby stack locations, not a native CPU profiler or object contents.
        stack = (Thread.main.backtrace_locations(0, 32) || []).map { |location| "#{location.path}:#{location.lineno}:in '#{location.base_label}'" }
        @stacks[@sample_count % @sample_capacity] = stack
        @sample_count += 1
      end
    end

    def allocation_sites
      counts, examined = Hash.new(0), 0
      ObjectSpace.each_object do |object|
        examined += 1
        break if examined > 100_000
        file = ObjectSpace.allocation_sourcefile(object)
        next unless file
        site = [file, ObjectSpace.allocation_sourceline(object)]
        counts[site] += 1 if counts.key?(site) || counts.length < 2_000
      end
      {scope: "Traced objects still alive at stop; not all allocated objects. Existing external traces can contribute. At most 100000 live objects examined, 2000 sites retained.",
       examined_objects: [examined, 100_000].min, scan_limit_reached: examined > 100_000,
       sites: counts.sort_by { |_, count| -count }.map { |(file, line), count| {file: file, line: line, live_objects: count} }}
    end

    def self.context(window = nil)
      {ruby: RUBY_DESCRIPTION, engine: RUBY_ENGINE, ruby_version: RUBY_VERSION, platform: RUBY_PLATFORM,
       canopus_version: Canopus::VERSION, zaniah_version: Zaniah::VERSION,
       yjit: !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?),
       zjit: !!(defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?),
       window: window&.class&.name, renderer: window&.device&.class&.name,
       scale_factor: window&.scale_factor,
       logical_size: window && {width: window.content_size.width, height: window.content_size.height}}
    end

    def self.validate_paths(paths, protected: [])
      reports = paths.compact.map { |path| File.expand_path(path) }
      raise ArgumentError, "diagnostic report paths must be distinct" unless reports.uniq.length == reports.length
      protected = protected.compact.map { |path| File.expand_path(path) }
      reports.each do |path|
        raise ArgumentError, "report directory does not exist: #{File.dirname(path)}" unless File.directory?(File.dirname(path))
        raise ArgumentError, "report path is a directory: #{path}" if File.directory?(path)
        raise ArgumentError, "report path must not be a symlink: #{path}" if File.symlink?(path)
        if protected.any? { |input| input == path || (File.exist?(path) && File.exist?(input) && File.identical?(path, input)) }
          raise ArgumentError, "report path overlaps an input or output file: #{path}"
        end
      end
      reports
    end

    def self.write_json(path, report)
      target = validate_paths([path]).first
      json = JSON.pretty_generate(report)
      Tempfile.create([".canopus-report-", ".json"], File.dirname(target), mode: File::RDWR, perm: 0o600) do |file|
        file.chmod(0o600)
        file.write(json)
        file.write("\n")
        file.flush
        file.fsync
        file.close
        File.rename(file.path, target)
      end
      target
    end

    def self.write_crash(path, exception, window: nil)
      write_json(path, {schema_version: 1, kind: "crash", generated_at: Time.now.utc.iso8601,
        context: context(window), exception: exception_details(exception),
        privacy: "Local only. Message and backtrace can contain sensitive paths or text; review before sharing. No environment, buffer contents or object dumps are collected."})
    end

    def self.exception_details(exception, depth = 0)
      result = {class: exception.class.name, message: clean_text(exception.message, 8_192),
        backtrace: (exception.backtrace || []).first(100).map { |line| clean_text(line, 2_048) }}
      result[:cause] = exception_details(exception.cause, depth + 1) if exception.cause && depth < 3 && exception.cause != exception
      result
    end
    private_class_method :exception_details

    def self.clean_text(value, limit) = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).slice(0, limit)
    private_class_method :clean_text
  end
end
