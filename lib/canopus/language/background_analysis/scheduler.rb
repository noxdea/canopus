# frozen_string_literal: true

# Two preparation threads and two named-handler processes are shared by
# all documents. No unbounded per-document threads or queued snapshots.
class Canopus::Language::BackgroundAnalysis::Scheduler
  BackgroundAnalysis = Canopus::Language.const_get(:BackgroundAnalysis, false)
  private_constant :BackgroundAnalysis

  @lock = Mutex.new
  class << self
    def acquire
      @lock.synchronize do
        @shared ||= new
        @owners = (@owners || 0) + 1
        @shared
      end
    end
    def release(scheduler)
      close = @lock.synchronize do
        next false unless @shared.equal?(scheduler)
        @owners -= 1
        if @owners.zero?
          @shared = nil
          true
        end
      end
      scheduler.shutdown if close
    end
  end

  def initialize
    @executor = Zaniah::TaskExecutor.new(workers: 2)
    @lock, @pool_lock, @jobs = Mutex.new, Mutex.new, []
  end
  def submit(snapshot, prior_syntax: nil)
    job = @lock.synchronize do
      return if @closed || @jobs.length >= 2
      BackgroundAnalysis::Job.new.tap { |value| @jobs << value }
    end
    job.future = @executor.background do
      begin
        job.check!
        payload = BackgroundAnalysis.prepare(snapshot, job)
        job.check!
        pool = @pool_lock.synchronize do
          job.check!
          @pool ||= Zaniah::ProcessPool.new(workers: 2,
            handler: "Canopus::Language::SyntaxWorker",
            requires: [File.expand_path("../syntax_worker.rb", __dir__)],
            load_paths: [File.expand_path("..", __dir__)], max_pending: 4, max_bytes: 16 << 20)
        end
        job.inner = pool.submit(payload)
        job.check!
        response = job.inner.await(timeout: 5)
        job.check!
        BackgroundAnalysis.decode(response, prior_syntax: prior_syntax)
      ensure
        job.inner&.cancel unless job.inner&.done?
        @lock.synchronize { @jobs.delete(job) }
      end
    end
    job
  end
  def shutdown
    @lock.synchronize { @closed = true; @jobs.each(&:cancel) }
    @pool_lock.synchronize { @pool&.shutdown }
  ensure
    @executor.shutdown
  end
end
