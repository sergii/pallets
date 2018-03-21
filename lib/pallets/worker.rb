module Pallets
  class Worker
    attr_reader :manager

    def initialize(manager)
      @manager = manager
      @current_job = nil
      @needs_to_stop = false
      @thread = nil
    end

    def start
      Pallets.logger.info "[worker] starting"
      @thread ||= Thread.new { work }
    end

    def graceful_shutdown
      Pallets.logger.info "[worker #{@thread.object_id}] graceful shutdown..."
      @needs_to_stop = true
    end

    def hard_shutdown
      return unless @thread
      Pallets.logger.info "[worker #{@thread.object_id}] hard shutdown, killing"
      @thread.raise Pallets::Shutdown
      Pallets.logger.info "[worker #{@thread.object_id}] killed"
    end

    private

    def work
      loop do
        break if @needs_to_stop

        Pallets.logger.info "[worker #{id}] picking work"
        @current_job = backend.pick_work id
        break if @needs_to_stop # no requeue because of extra reliable queue
        if @current_job.nil?
          Pallets.logger.info "[worker #{id}] nothing new, skipping"
          next
        end

        process @current_job.dup

        @current_job = nil
      end
      Pallets.logger.info "[worker #{id}] done"
      @manager.remove_worker(self)
    rescue Pallets::Shutdown
      Pallets.logger.error "[worker #{id}] shutdown"
      @manager.remove_worker(self)
    rescue => ex
      Pallets.logger.error "[worker #{id}] died:"
      Pallets.logger.error ex
      # Pallets.logger.error ex.backtrace
      @manager.restart_worker(self)
    end

    def process(job)
      Pallets.logger.info "[worker #{id}] picked job: #{job}"
      begin
        job_hash = serializer.load(job)
      rescue
        # We ensure only valid jobs are created. If something fishy reaches this
        # point, just discard it
        backend.discard(job, id)
        return
      end

      Pallets.logger.info "[worker #{id}] working"
      task_class = job_hash["class_name"].constantize
      task = task_class.new(job_hash["context"])
      begin
        task.run
      rescue => ex
        handle_job_error(ex, job, job_hash)
      else
        Pallets.logger.info "[worker #{id}] saving work"
        backend.save_work(job_hash["wfid"], job, id)
      end
    end

    def handle_job_error(ex, job, job_hash)
      Pallets.logger.error "[worker #{id}] failed:"
      Pallets.logger.error ex
      failures = job_hash.fetch('failures', 0) + 1
      new_job = serializer.dump(job_hash.merge(
        'failures' => failures,
        'failed_at' => Time.now.to_f,
        'error_class' => ex.class.name,
        'error_message' => ex.message
      ))
      if failures < 15
        Pallets.logger.info "[worker #{id}] scheduling for retry"
        retry_at = Time.now.to_f + backoff_in_seconds(failures)
        backend.retry_work(new_job, job, retry_at, id)
      else
        Pallets.logger.info "[worker #{id}] killing"
        backend.kill_work(new_job, job, Time.now.to_f, id)
      end
    end

    def backoff_in_seconds(count)
      count ** 4 + 6
    end

    def id
      Thread.current.object_id
    end

    def backend
      @backend ||= Pallets.backend
    end

    def serializer
      @serializer ||= Pallets.serializer
    end
  end
end
