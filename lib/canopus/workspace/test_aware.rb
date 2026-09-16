# frozen_string_literal: true

require "zaniah/ui"

module Canopus
  module Workspace::TestAware
    TEST_LABEL_LIMIT = 200

    attr_reader :tests

    def initialize_tests
      @tests = [].freeze
      @test_generation = 0
      @test_discovery_started = @test_discovery_pending = @test_discovery_requested = false
      @test_discovery_thread = @test_discovery_token = nil
      @test_discovery = nil
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
        @test_discovery_pending = false
        @test_tree&.replace([test_status_node(:error, test_label("Cannot discover tests: #{error.message}"))])
        self.message = test_label("Cannot discover tests: #{error.message}")
      else
        @tests = result
        @test_discovery_pending = false
        @test_tree&.replace(test_nodes)
        @panels.badge("test", @tests.empty? ? nil : @tests.length)
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
      bounded_test_label([*test.groups, test.name], separator: " › ", suffix: " · line #{test.line}")
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

      candidate = File.join(@root, test.path)
      raise Error, "Test target is not a file" if File.lstat(candidate).symlink?
      path = File.realpath(candidate)
      prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      raise Error, "Test target is outside the workspace" unless path.start_with?(prefix) && File.file?(path)

      target = open(path)
      row = test.line - 1
      raise Error, "Test target line is no longer valid" unless row.between?(0, target.buffer.line_count - 1)
      target.select(target.buffer.rope.line_start(row))
      target.reveal_cursor
      true
    rescue Error, SystemCallError => error
      self.message = "Cannot open test: #{error.message}"
      false
    end
  end
end
