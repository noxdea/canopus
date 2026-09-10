# frozen_string_literal: true

class Canopus::Project::Watcher
  Event = Struct.new(:type, :path, keyword_init: true)
  attr_reader :backend, :snapshot

  # Native adapters implement #poll(timeout:) and #close. Polling is always
  # available and also reconciles coalesced native directory notifications.
  def initialize(project, interval: 0.5, native: nil)
    @project = project
    @interval = interval
    @native = native
    @backend = native ? :native : :polling
    @snapshot = capture
    @running = false
  end

  def poll(timeout: 0)
    if @native
      return [] if @native.poll(timeout: timeout).empty?
    elsif timeout.positive?
      sleep(timeout)
    end
    current = capture
    events = (@snapshot.keys - current.keys).map { |path| Event.new(type: :deleted, path: path) }
    current.each do |path, stamp|
      type = !@snapshot.key?(path) ? :created : @snapshot[path] != stamp ? :modified : nil
      events << Event.new(type: type, path: path) if type
    end
    @snapshot = current
    events.sort_by(&:path)
  end

  def start(&block)
    raise ArgumentError, "watch callback required" unless block
    return self if @running
    @running = true
    @thread = Thread.new { poll(timeout: @interval).each(&block) while @running }
    self
  end

  def close
    @running = false
    @thread&.join unless @thread == Thread.current
    @native&.close
    self
  end

  private

  def capture
    @project.files.to_h do |relative|
      stat = File.stat(@project.path(relative))
      [relative, [stat.ino, stat.size, stat.mtime, stat.ctime]]
    rescue Errno::ENOENT
      [relative, nil]
    end.reject { |_, stamp| stamp.nil? }
  end
end
