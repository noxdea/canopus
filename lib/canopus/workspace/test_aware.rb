# frozen_string_literal: true

require "zaniah/ui"

module Canopus
  module Workspace::TestAware
    TEST_LABEL_LIMIT = 200
    TEST_COLORS = {idle: :muted, running: :accent, success: "#3fb950",
                   failure: :error, skipped: :muted}.freeze
    TEST_MARKS = {idle: "▶", running: "●", success: "✓", failure: "×", skipped: "○"}.freeze

    TestClick = Data.define(:workspace, :tests) do
      def call(_editor, _row) = workspace.run_tests(tests)
    end
    private_constant :TestClick

    attr_reader :tests

    def test_results = @test_results.dup.freeze

    def initialize_tests
      @tests = [].freeze
      @test_generation = 0
      @test_discovery_started = @test_discovery_pending = @test_discovery_requested = false
      @test_discovery_thread = @test_discovery_token = nil
      @test_discovery = nil
      @tests_by_path = {}.freeze
      @test_results, @test_executions, @test_outputs = {}, {}, {}
      @test_diagnostic_snapshot = {}.freeze
      @decorations.register(:test) { |buffer, rows| test_decorations(buffer, rows) }
      nil
    end

    def test_tree
      @test_tree ||= Zaniah::UI::TreeView.new(test_nodes, height: 600).on_select do |value, _event, _context|
        select_test(value)
      end
      refresh_tests unless @test_discovery_started
      @test_tree
    end

    def refresh_tests
      raise Error, "Workspace closed" if @closed

      @test_generation += 1
      @test_discovery_started = @test_discovery_pending = @test_discovery_requested = true
      @test_tree&.replace([test_status_node(:discovering, "Discovering tests…")])
      @panels.badge("test", nil)
      start_test_discovery
      @window&.request_frame
      @test_discovery_thread
    end

    def test_discovery_pending? = !!@test_discovery_pending

    def run_test(test) = run_tests([test])

    def run_tests(tests)
      unless tests.is_a?(Array) && !tests.empty? && tests.length <= TestRunner::Discovery::MAX_TESTS &&
          tests.all? { |test| test.is_a?(TestRunner::Test) && @tests.include?(test) } &&
          tests.all? { |test| test.framework == tests.first.framework && test.path == tests.first.path &&
            test.line == tests.first.line }
        raise Error, "Unknown tests"
      end

      tests = tests.dup.freeze
      test = tests.first
      task = TestRunner::Execution.task(test, root: @root, tests: tests)
      previous = tests.filter_map { |candidate| @test_outputs[candidate] }.uniq
      output = start_task(task, nil)
      previous.each do |entry|
        @task_runner.stop(entry)
        old = @test_executions.delete(entry.id)
        old&.cancel
        old&.tests&.each do |candidate|
          @test_outputs.delete(candidate) if @test_outputs[candidate].equal?(entry)
          @test_results[candidate] = old.finish(nil) if @tests.include?(candidate)
        end
      end
      execution = TestRunner::Execution.new(test, output, generation: @test_generation, tests: tests)
      @test_executions[output.id] = execution
      tests.each do |candidate|
        @test_outputs[candidate] = output
        @test_results[candidate] = TestRunner::Result.new(:running, nil, nil, nil).freeze
      end
      refresh_test_results
      output
    end

    def toggle_tests
      if @panels.visible?("test")
        @panels.hide("test")
      else
        @panels.show("test")
        refresh_tests unless @test_discovery_started
      end
      @window&.request_frame
    end

    def close_tests
      @test_generation += 1
      @test_discovery_requested = @test_discovery_pending = false
      @test_discovery_token = nil
      thread, @test_discovery_thread = @test_discovery_thread, nil
      thread.join if thread && thread != Thread.current
      @test_executions.clear
      @test_outputs.clear
      @test_results.clear
      publish_test_diagnostics
      nil
    end

    private

    def start_test_discovery
      return if @closed || @test_discovery_thread&.alive? || !@test_discovery_requested

      generation = @test_generation
      @test_discovery_requested = false
      token = @test_discovery_token = Object.new.freeze
      thread = Thread.new do
        result = error = nil
        begin
          discovery = @test_discovery || TestRunner::Discovery.new(root: @root)
          result = discovery.discover(cancelled: -> { @closed || generation != @test_generation })
        rescue StandardError => failure
          error = failure
        ensure
          post { complete_test_discovery(token, generation, result, error) } unless @closed
        end
      end
      thread.report_on_exception = false
      @test_discovery_thread = thread
    end

    def complete_test_discovery(token, generation, result, error)
      return unless @test_discovery_token.equal?(token)

      @test_discovery_thread = @test_discovery_token = nil
      if generation != @test_generation || @test_discovery_requested
        start_test_discovery
      elsif error
        @tests = [].freeze
        @tests_by_path = {}.freeze
        @test_results.clear
        @test_discovery_pending = false
        @test_tree&.replace([test_status_node(:error, test_label("Cannot discover tests: #{error.message}"))])
        self.message = test_label("Cannot discover tests: #{error.message}")
        @decorations.invalidate(:test)
        publish_test_diagnostics
      else
        @tests = result
        @tests_by_path = @tests.group_by(&:path).transform_values { |tests| tests.freeze }.freeze
        known = @tests.to_h { |test| [test, true] }
        @test_results.delete_if { |test, result| !known.key?(test) || result.status == :running }
        @test_discovery_pending = false
        @test_tree&.replace(test_nodes)
        @panels.badge("test", @tests.empty? ? nil : @tests.length)
        @decorations.invalidate(:test)
        publish_test_diagnostics
      end
      @window&.request_frame
      nil
    end

    def test_nodes
      return [test_status_node(:discovering, "Discovering tests…")].freeze if @test_discovery_pending
      return [test_status_node(:empty, "No tests found")].freeze if @tests.empty?

      @tests.group_by(&:path).map do |path, tests|
        children = tests.map do |test|
          {id: [:test, test.framework, test.path, test.offset].freeze,
           label: test_case_label(test), value: test}.freeze
        end.freeze
        {id: [:test_file, path].freeze, label: test_label(path), value: nil, children: children}.freeze
      end.freeze
    end

    def test_status_node(kind, label)
      {id: [:test_status, kind].freeze, label: label.freeze, value: nil}.freeze
    end

    def test_label(value)
      bounded_test_label([value])
    end

    def test_case_label(test)
      mark = TEST_MARKS.fetch(@test_results[test]&.status || :idle)
      label = bounded_test_label([*test.groups, test.name], separator: " › ", suffix: " · line #{test.line}")
      bounded_test_label(["#{mark} ", label])
    end

    def bounded_test_label(parts, separator: "", suffix: nil)
      label = +""
      parts.each_with_index do |part, index|
        if index.positive? && !append_test_label(label, separator)
          return finish_test_label(label)
        end
        return finish_test_label(label) unless append_test_label(label, part)
      end
      return finish_test_label(label) if suffix && !append_test_label(label, suffix)

      label.rstrip.freeze
    end

    def append_test_label(label, value)
      value.to_s.each_char do |character|
        character = " " if character.match?(/\s/)
        next if character == " " && (label.empty? || label.end_with?(" "))
        return false if label.length >= TEST_LABEL_LIMIT

        label << character
      end
      true
    end

    def finish_test_label(label)
      label.rstrip!
      label.slice!(TEST_LABEL_LIMIT - 1..) if label.length >= TEST_LABEL_LIMIT
      label << "…"
      label.freeze
    end

    def select_test(test)
      return false unless test.is_a?(TestRunner::Test)

      result = @test_results[test]
      if result&.status == :failure
        begin
          return select_test_location(result.path, result.line)
        rescue Error, SystemCallError
          # The file may have changed since the run; use the declaration below.
        end
      end
      select_test_location(test.path, test.line)
    rescue Error, SystemCallError => error
      self.message = "Cannot open test: #{error.message}"
      false
    end

    def select_test_location(relative, line)
      relative = TestRunner.normalize_path(relative)
      raise Error, "Test target path is invalid" unless relative

      candidate = File.join(@root, relative)
      raise Error, "Test target is not a file" if File.lstat(candidate).symlink?
      path = File.realpath(candidate)
      prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      raise Error, "Test target is outside the workspace" unless path.start_with?(prefix) && File.file?(path)

      target = open(path)
      row = line - 1
      raise Error, "Test target line is no longer valid" unless row.between?(0, target.buffer.line_count - 1)
      target.select(target.buffer.rope.line_start(row))
      target.reveal_cursor
      true
    end

    def test_decorations(buffer, rows)
      return [] unless buffer.path&.start_with?(@root + File::SEPARATOR)

      relative = buffer.path.delete_prefix(@root + File::SEPARATOR).tr(File::SEPARATOR, "/")
      visible = @tests_by_path.fetch(relative, []).select { |test| rows.cover?(test.line - 1) }
      visible.group_by(&:line).map do |line, tests|
        tests = tests.freeze
        status = test_row_status(tests)
        label = tests.length == 1 ? "#{TEST_MARKS.fetch(status)} Run #{test_label(tests.first.name)}" :
          "#{TEST_MARKS.fetch(status)} Run #{tests.length} tests on line #{line}"
        style = {color: TEST_COLORS.fetch(status), gutter_offset: 1, gutter_width: 4,
                 hit_offset: 0, hit_width: 6}.freeze
        Decoration::Item.new(:gutter, nil, line - 1, label, style, 30, :test,
          TestClick.new(self, tests).freeze)
      end
    end

    def test_row_status(tests)
      statuses = tests.filter_map { |test| @test_results[test]&.status }
      return :running if statuses.include?(:running)
      return :failure if statuses.include?(:failure)
      return :idle if statuses.length < tests.length
      return :skipped if statuses.all? { |status| status == :skipped }

      :success
    end

    def capture_test_output(output, data)
      @test_executions[output.id]&.append(data)
    end

    def cancel_test_output(output)
      @test_executions[output&.id]&.cancel
    end

    def complete_test_output(output)
      execution = @test_executions.delete(output.id)
      return unless execution

      @test_outputs.delete_if { |_test, entry| entry.equal?(output) }
      status = output.terminal.status if output.terminal.respond_to?(:status)
      result = normalize_test_result(execution, execution.finish(status))
      if execution.generation == @test_generation
        execution.tests.each do |test|
          @test_results[test] = test_result_for(test, result) if @tests.include?(test)
        end
      end
      refresh_test_results
    rescue StandardError => error
      message = "#{execution.test.name} failed: #{error.message}".encode(Encoding::UTF_8,
        invalid: :replace, undef: :replace).delete("\0").byteslice(0, 4_096).scrub("")
      if execution.generation == @test_generation
        execution.tests.each do |test|
          next unless @tests.include?(test)

          @test_results[test] = TestRunner::Result.new(:failure, test.path, test.line, message).freeze
        end
      end
      refresh_test_results
    end

    def forget_test_output(output)
      execution = @test_executions.delete(output.id)
      return unless execution

      execution.cancel
      @test_outputs.delete_if { |_test, entry| entry.equal?(output) }
      if execution.generation == @test_generation
        execution.tests.each do |test|
          @test_results[test] = execution.finish(nil) if @tests.include?(test)
        end
      end
      refresh_test_results
    end

    def refresh_test_results
      @test_tree&.replace(test_nodes)
      @decorations.invalidate(:test)
      publish_test_diagnostics
      @window&.request_frame
      nil
    end

    def normalize_test_result(execution, result)
      return result unless result.status == :failure

      path = File.join(@root, execution.test.path)
      entry = File.lstat(path)
      return result.with(line: execution.test.line).freeze if entry.symlink? || !entry.file? ||
        entry.size > TestRunner::Discovery::MAX_FILE_BYTES

      absolute = File.realpath(path)
      prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      return result.with(line: execution.test.line).freeze unless absolute.start_with?(prefix)

      source = File.open(absolute, "rb") { |file| file.read(TestRunner::Discovery::MAX_FILE_BYTES + 1) }
      return result.with(line: execution.test.line).freeze if source.bytesize > TestRunner::Discovery::MAX_FILE_BYTES

      lines = [source.count("\n") + 1, 1].max
      line = result.line.between?(1, lines) ? result.line : execution.test.line.clamp(1, lines)
      result.with(line: line).freeze
    rescue SystemCallError
      result.with(line: execution.test.line).freeze
    end

    def test_result_for(test, result)
      return result unless result.status == :failure

      message = "#{test.name} failed".byteslice(0, 4_096).scrub("")
      result.with(message: message).freeze
    end

    def publish_test_diagnostics
      grouped = @test_results.each_with_object(Hash.new { |hash, uri| hash[uri] = [] }) do |(test, result), values|
        next unless result.status == :failure

        path = File.join(@root, result.path)
        uri = Sadr::Protocol.uri(path)
        line = result.line - 1
        values[uri] << {"message" => result.message, "severity" => 1, "source" => "test",
          "range" => {"start" => {"line" => line, "character" => 0},
                      "end" => {"line" => line, "character" => 0}}}
      end
      snapshot = grouped.transform_values { |values| values.first(Diagnostics::PUBLICATION_LIMIT).freeze }.freeze
      changed = (@test_diagnostic_snapshot.keys | snapshot.keys).select do |uri|
        @test_diagnostic_snapshot[uri] != snapshot[uri]
      end
      return false if changed.empty?

      changed.each { |uri| @diagnostics.publish(:test, uri, snapshot.fetch(uri, []), notify: false) }
      @test_diagnostic_snapshot = snapshot
      diagnostics_changed(changed)
      true
    end
  end
end
