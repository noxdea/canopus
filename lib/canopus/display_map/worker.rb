# frozen_string_literal: true

class Canopus::DisplayMap::Worker
  BATCH_LINES = 32
  QUEUE_LIMIT = 8
  Job = Data.define(:generation, :tree, :builder, :prefix)
  Result = Data.define(:generation, :first, :lines, :error)
  Cancelled = Class.new(StandardError)
  private_constant :Cancelled
  attr_reader :thread, :results

  def initialize
    @requests, @results = Queue.new, SizedQueue.new(QUEUE_LIMIT)
    @thread = Thread.new { run }
    @thread.name = "canopus-wrap"
    @thread.report_on_exception = false
  end

  def submit(generation, tree, builder, prefix)
    @generation = generation
    @requests.clear
    @results.clear
    @requests << Job.new(generation, tree, builder, prefix)
  end

  def close
    return if @closed
    @closed = true
    @generation = nil
    @requests.close
    @results.close
    # Cancellation checkpoints normally finish in milliseconds. No native
    # resource or shared mutable document state belongs to this worker.
    @thread.kill unless @thread.join(1)
    @thread.join(0.1)
    @results.clear
  end

  private

  def run
    while (job = @requests.pop)
      yielded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      checkpoint = lambda do
        raise Cancelled if @closed || @generation != job.generation
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - yielded_at >= 0.002
          Thread.pass
          yielded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
      begin
        first, lines, bytes = nil, [], 0
        flush = lambda do
          unless lines.empty?
            checkpoint.call
            @results << Result.new(job.generation, first, lines.freeze, nil)
            first, lines, bytes = nil, [], 0
          end
        end
        source_rows(job) do |row|
          checkpoint.call
          flush.call if first && row != first + lines.length
          first ||= row
          value = job.builder.line(row, checkpoint: checkpoint)
          lines << value
          bytes += value.rows.sum { |line| line.text.bytesize + line.offsets.length * 8 }
          flush.call if lines.length >= BATCH_LINES || bytes >= 65_536
        end
        flush.call
      rescue Cancelled
        next
      rescue ClosedQueueError
        break if @closed
      rescue StandardError => error
        @results << Result.new(job.generation, 0, [].freeze, error) unless @closed
      ensure
        job = checkpoint = flush = lines = value = nil
      end
    end
  rescue ClosedQueueError
    nil
  end

  def source_rows(job)
    count = job.tree.prefix_summary(job.prefix).pending_rows
    count.times { |index| yield job.tree.locate(index, :pending_rows)[0] }
    (job.prefix...job.tree.size).each { |row| yield row }
  end
end
