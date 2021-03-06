module Pallets
  class Workflow
    extend DSL::Workflow

    attr_reader :context

    def initialize(context = {})
      @id = nil
      @context = context
    end

    def run
      backend.run_workflow(id, jobs_with_order)
      id
    end

    def id
      @id ||= begin
        initials = self.class.name.gsub(/[^A-Z]+([A-Z])/, '\1')[0,3]
        random = SecureRandom.hex(5)
        "P#{initials}#{random}".upcase
      end
    end

    private

    def jobs_with_order
      self.class.graph.sorted_with_order.map do |task_name, order|
        job = serializer.dump(job_hash.merge(self.class.task_config[task_name]))
        [order, job]
      end
    end

    def job_hash
      {
        'workflow_id' => id,
        'context'     => context,
        'created_at'  => Time.now.to_f
      }
    end

    def backend
      Pallets.backend
    end

    def serializer
      Pallets.serializer
    end

    def self.task_config
      @task_config ||= {}
    end

    def self.graph
      @graph ||= Graph.new
    end
  end
end
