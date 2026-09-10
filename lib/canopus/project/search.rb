# frozen_string_literal: true

require "rbconfig"
require_relative "search_worker"

class Canopus::Project::Search
  SearchWorker = Canopus::Project.const_get(:SearchWorker, false)
  private_constant :SearchWorker

  Match = Struct.new(:path, :line, :column, :byte_offset, :text, :match, keyword_init: true)
  DEFAULT_MAX_SIZE = 10 * 1024 * 1024
  Child = Struct.new(:pid, :input, :output, :queue, :writer, :reader, :waiter)
  private_constant :Child

  def initialize(project)
    @project = project
  end

  # Results are ordered by relative path and byte offset, even with workers.
  def call(pattern, workers: 4, max_size: DEFAULT_MAX_SIZE, extensions: nil, limit: nil,
    case_sensitive: true, cancelled: nil, paths: nil, &block)
    raise ArgumentError, "workers must be between 1 and 32" unless workers.is_a?(Integer) && workers.between?(1, 32)
    raise ArgumentError, "limit must be positive" if limit && (!limit.is_a?(Integer) || !limit.positive?)
    raise ArgumentError, "max_size must be nonnegative" if max_size && (!max_size.is_a?(Integer) || max_size.negative?)
    max_size = [max_size || SearchWorker::MAX_FILE_BYTES, SearchWorker::MAX_FILE_BYTES].min
    expression = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern), case_sensitive ? 0 : Regexp::IGNORECASE)
    expression = Regexp.new(expression.source, expression.options, timeout: expression.timeout || 0.25)
    files = []
    (paths || @project.files(extensions: extensions, max_size: max_size)).each do |relative|
      SearchWorker.check_cancelled(cancelled)
      raise ArgumentError, "invalid search path" unless relative.is_a?(String) && relative.valid_encoding? && !relative.include?("\0")
      @project.path(relative)
      files << relative
    end
    files.sort!
    return [] if files.empty?
    results = []
    receive = receiver(results)
    if workers > 1 && files.length > 1
      parallel(files, expression, [workers, files.length].min, max_size, limit, cancelled, &receive)
    else
      SearchWorker.scan(@project.root, files, expression, max_size, limit, cancelled: cancelled, &receive)
    end
    SearchWorker.check_cancelled(cancelled)
    results.each(&block) if block
    results
  rescue SearchWorker::Cancelled
    []
  end

  private

  def receiver(results)
    path = number = offset = raw = text = nil
    lambda do |message|
      case message[0]
      when :line
        _, path, number, offset, raw = message
        text = raw.chomp.freeze
      when :matches
        message[1].each do |column, first, last|
          results << Match.new(path: path, line: number, column: column,
            byte_offset: offset + first, text: text, match: raw.byteslice(first, last - first))
        end
      when :error then raise IOError, "search worker: #{message[1]}"
      when :done then nil
      else raise IOError, "invalid search worker response"
      end
    end
  end

  def parallel(files, expression, count, max_size, limit, cancelled)
    children, first = [], 0
    count.times do |index|
      SearchWorker.check_cancelled(cancelled)
      length = files.length / count + (index < files.length % count ? 1 : 0)
      config = [@project.root, files.slice(first, length), expression, max_size, limit, expression.timeout]
      children << start_child(config)
      first += length
    end
    remaining = limit
    children.each do |child|
      loop do
        SearchWorker.check_cancelled(cancelled)
        begin
          message = child.queue.pop(true)
        rescue ThreadError
          sleep 0.005
          next
        end
        raise message if message.is_a?(Exception)
        break if message[0] == :done
        if message[0] == :matches && remaining
          message[1] = message[1].first(remaining)
          remaining -= message[1].length
        end
        yield message
        return if remaining == 0
      end
    end
  ensure
    children&.each { |child| stop_child(child) }
  end

  def start_child(config)
    child_input, input = IO.pipe
    output, child_output = IO.pipe
    child = Child.new(nil, input, output, SizedQueue.new(2))
        child.pid = Process.spawn({"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby, "--disable-gems",
          File.expand_path("search_worker/runner.rb", __dir__), in: child_input, out: child_output, err: File::NULL)
    child.waiter = Process.detach(child.pid)
    child_input.close
    child_output.close
    child.writer = Thread.new do
      SearchWorker.write_frame(input, config)
    rescue StandardError => error
      enqueue(child, error)
    ensure
      input.close unless input.closed?
    end
    child.reader = Thread.new do
      loop do
        message = SearchWorker.read_frame(output)
        break unless enqueue(child, message)
        break if message[0] == :done
      end
    rescue StandardError => error
      enqueue(child, error)
    end
    child
  rescue Exception
    stop_child(child) if child
    [child_input, child_output, input, output].compact.each { |io| io.close unless io.closed? }
    raise
  end

  def stop_child(child)
    child.queue.close
    if child.waiter && !child.waiter.join(0)
      signal(child, "TERM")
      unless child.waiter.join(0.2)
        signal(child, "KILL")
        child.waiter.join(0.5)
      end
    end
    [child.input, child.output].compact.each { |io| io.close unless io.closed? }
    [child.writer, child.reader].compact.each do |thread|
      thread.kill unless thread.join(0.2)
      thread.join(0.1)
    end
  end

  def enqueue(child, message)
    child.queue.push(message)
  rescue ClosedQueueError
    false
  end

  def signal(child, name)
    Process.kill(name, child.pid)
  rescue Errno::ESRCH, Errno::EINVAL
    nil
  end
end
