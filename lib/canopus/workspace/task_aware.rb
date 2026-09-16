# frozen_string_literal: true

module Canopus
  class Workspace
    module TaskAware
      attr_reader :task_runner

      def initialize_tasks
        options = @settings["terminal"]
        @task_runner = Task::Runner.new(scrollback: options["scrollback_lines"],
          queue_limit_bytes: options["queue_limit_bytes"], report: ->(error) { post { notify("Cannot close task: #{error.message}") } })
        @task_matchers, @task_finished, @task_diagnostic_snapshot = {}, {}, {}.freeze
      end

      def task_outputs = @task_runner.entries
      def task_output = @task_runner.active
      def task_terminal = @task_runner.terminal
      def task_output_visible = @panels.visible?("output") && @docks[:bottom][:visible]

      def show_tasks
        configuration = Task::Configuration.new(root: @root)
        if configuration.tasks.empty?
          self.message = "No tasks configured in .canopus/tasks.jsonc"
          return false
        end
        self.palette = {kind: :tasks, query: +"", index: 0,
          matches: configuration.tasks.map { |task| task.fetch("label") },
          items: configuration.tasks, task_configuration: configuration}
        update_palette
      end

      def run_task(task)
        configuration = Task::Configuration.new(root: @root)
        source = task.is_a?(String) ? task : configuration.tasks.find { |candidate| candidate == task }
        resolved = configuration.resolve(source, **task_context)
        matcher = resolved["problem_matcher"] && configuration.problem_matcher(resolved["problem_matcher"])
        raise Error, "unknown problem matcher: #{resolved['problem_matcher']}" if resolved["problem_matcher"] && !matcher
        start_task(resolved, matcher)
      end

      def accept_task_palette
        state = @palette
        index = state[:indices] ? state[:indices][state[:index]] : state[:index]
        source = index && state[:items][index]
        configuration = state[:task_configuration]
        self.palette = nil
        return unless source && configuration

        resolved = configuration.resolve(source, **task_context)
        matcher = resolved["problem_matcher"] && configuration.problem_matcher(resolved["problem_matcher"])
        raise Error, "unknown problem matcher: #{resolved['problem_matcher']}" if resolved["problem_matcher"] && !matcher
        start_task(resolved, matcher)
      end

      def show_task_output(output = task_output)
        if output && (index = task_outputs.index { |entry| entry.equal?(output) })
          @task_runner.activate(index)
        end
        @panels.hide("terminal") if @panels.visible?("terminal")
        @panels.hide("debug_console") if @panels.visible?("debug_console")
        @panels.show("output")
        @window&.request_frame
        output
      end

      def toggle_task_output
        task_output_visible ? @panels.hide("output") : show_task_output
      end

      def activate_task_output(index)
        output = @task_runner.activate(index)
        @window&.request_frame
        output
      end

      def close_task_output(index = @task_runner.active_index)
        output = @task_runner.remove(index)
        forget_task_output(output) if output
        @panels.hide("output") if task_outputs.empty?
        @window&.request_frame
        output
      end

      def stop_task(output = task_output)
        stopped = @task_runner.stop(output)
        self.message = "No running task selected" unless stopped
        @window&.request_frame
        stopped
      end

      def drain_task_outputs
        changed = @task_runner.drain(max_bytes: @settings["terminal"]["max_bytes_per_frame"]) do |output, data, seconds|
          matcher = @task_matchers[output.id]
          matcher&.feed(data.to_s, max_seconds: seconds)
          !matcher || !matcher.pending?
        end
        @task_runner.completed.each do |output|
          unless @task_finished[output.id]
            @task_finished[output.id] = true
            @task_matchers[output.id]&.finish
          end
          next unless output.presentation.fetch("reveal") == "silent"
          status = output.terminal.status if output.terminal.respond_to?(:status)
          show_task_output(output) if status && !status.success?
        end
        @window&.request_frame if changed || @task_runner.pending?
        changed
      end

      def resize_task_output(columns, rows) = @task_runner.resize(columns, rows)

      def task_output_title(output)
        suffix = @task_runner.running?(output) ? " ●" : ""
        "#{output.label}#{suffix}"
      end

      def close_tasks
        @task_runner.close
      ensure
        @task_matchers.clear
        @task_finished.clear
        publish_task_diagnostics
      end

      private

      def start_task(task, matcher)
        output = @task_runner.run(task)
        cleanup_stale_task_outputs
        if matcher
          @task_matchers[output.id] = Task::ProblemMatcher.new(matcher, root: @root) { publish_task_diagnostics }
        end
        show_task_output(output) if output.presentation.fetch("reveal") == "always"
        @window&.request_frame
        output
      end

      def cleanup_stale_task_outputs
        ids = task_outputs.map(&:id)
        (@task_matchers.keys | @task_finished.keys).each do |id|
          next if ids.include?(id)
          @task_matchers.delete(id)
          @task_finished.delete(id)
        end
        publish_task_diagnostics
      end

      def forget_task_output(output)
        @task_matchers.delete(output.id)
        @task_finished.delete(output.id)
        publish_task_diagnostics
      end

      def publish_task_diagnostics
        grouped = @task_matchers.values.each_with_object(Hash.new { |hash, uri| hash[uri] = [] }) do |matcher, result|
          matcher.diagnostics.each { |uri, values| result[uri].concat(values) }
        end
        snapshot = grouped.to_h do |uri, values|
          [uri, values.first(Diagnostics::PUBLICATION_LIMIT).freeze]
        end
        snapshot.freeze
        changed = (@task_diagnostic_snapshot.keys | snapshot.keys).select do |uri|
          @task_diagnostic_snapshot[uri] != snapshot[uri]
        end
        return false if changed.empty?

        changed.each do |uri|
          @diagnostics.publish(:task, uri, snapshot.fetch(uri, []), notify: false)
        end
        @task_diagnostic_snapshot = snapshot
        changed.freeze
        @window ? post { diagnostics_changed(changed) } : diagnostics_changed(changed)
        true
      end

      def task_context
        current = editor
        file = current&.buffer&.path
        line_number = current && current.buffer.rope.point_at(current.primary.head).row + 1
        selected_text = nil
        if current && !current.primary.empty?
          range = current.primary.range
          raise Error, "selectedText exceeds 1 MiB" if range.size > Task::Configuration::MAX_EXPANDED_BYTES
          selected_text = current.buffer.rope.byteslice(range).to_s
        end
        {file: file, line_number: line_number, selected_text: selected_text}
      end
    end
  end
end
