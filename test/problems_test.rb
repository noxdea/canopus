# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ProblemsTest < Minitest::Test
  class Client
    def state = :running
    def stop = nil
    def change(*) = nil
  end

  def setup
    @root = Dir.mktmpdir("canopus-problems-")
    @first = File.join(@root, "first.rb")
    @second = File.join(@root, "second.rb")
    File.write(@first, "first\n")
    File.write(@second, "second\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @editor = @workspace.open(@first)
    @client = Client.new
    @uri = Sadr::Protocol.uri(@editor.buffer.path)
    @workspace.clients["ruby"] = @client
    key = [@client, @editor.buffer]
    @workspace.instance_variable_set(:@opened_lsp_documents, {key => true})
    subscription = @editor.buffer.on_edit do |patch|
      @workspace.send(:sync_language_document, @client, @uri, @editor.buffer, patch)
    end
    @workspace.instance_variable_set(:@language_document_subscriptions, {key => subscription})
  end

  def teardown
    @workspace.close
    FileUtils.remove_entry(@root)
  end

  def diagnostic(message, severity: 1, line: 0, character: 0)
    {"message" => message, "severity" => severity, "range" => {
      "start" => {"line" => line, "character" => character},
      "end" => {"line" => line, "character" => character + 1}
    }}
  end

  def publish(values, version: @editor.buffer.version)
    @workspace.send(:accept_diagnostic_notification, @client,
      {"uri" => @uri, "version" => version, "diagnostics" => values})
  end

  def tree_source
    @workspace.problems_tree.instance_variable_get(:@source)
  end

  def test_lsp_diagnostics_move_to_registry_and_remain_version_safe
    publish([diagnostic("server error")])

    assert_equal ["server error"], @workspace.diagnostics.all(source: :lsp).map { |entry| entry.diagnostic["message"] }
    refute_empty @workspace.diagnostic_decorations(@editor.buffer, 0...1)
    @editor.insert_text("x", auto_indent: false)
    assert_empty @workspace.diagnostic_decorations(@editor.buffer, 0...1)
    assert_empty tree_source
    assert_equal 0, @workspace.diagnostics.counts[:error]

    publish([diagnostic("stale")], version: @editor.buffer.version - 1)
    assert_empty tree_source
    publish([diagnostic("fresh")])
    assert_equal ["fresh"], @workspace.diagnostics.all(source: :lsp).map { |entry| entry.diagnostic["message"] }

    versions = @workspace.instance_variable_get(:@diagnostic_versions)
    publish([diagnostic("invalid", severity: 5)])
    assert_equal @editor.buffer.version, versions.dig(@client, @uri)
    assert_equal ["fresh"], @workspace.diagnostics.all(source: :lsp).map { |entry| entry.diagnostic["message"] }

    @workspace.send(:forget_language_document, @client, @editor.buffer)
    assert_empty @workspace.diagnostics.all(source: :lsp)
  end

  def test_problems_tree_filters_all_sources_and_jumps_to_local_files
    publish([diagnostic("server error")])
    second_uri = Sadr::Protocol.uri(File.realpath(@second))
    @workspace.diagnostics.publish(:task, second_uri, [diagnostic("style warning", severity: 2, character: 1)])
    @workspace.diagnostics.publish(:test, second_uri, [diagnostic("test failure")])
    @workspace.call("panel.problems")

    assert @workspace.panels.visible?(:problems)
    assert_equal 2, tree_source.length
    assert_equal 3, @workspace.panels.fetch(:problems).badge
    @workspace.filter_problems(severity: :warning, source: :task, text: "STYLE")
    assert_equal ["second.rb"], tree_source.map { |node| node[:label] }
    assert_equal 1, tree_source.first[:children].length

    @workspace.call("problems.filter")
    @workspace.palette[:query].replace("source:test severity:error failure")
    @workspace.palette_accept
    assert_equal [:test], tree_source.first[:children].map { |child| child[:value].source }

    entry = tree_source.first[:children].first[:value]
    assert @workspace.send(:select_problem, entry)
    assert_equal File.realpath(@second), @workspace.editor.buffer.path
    assert_equal 0, @workspace.editor.primary.head
  end

  def test_problem_filter_and_jump_reject_invalid_external_values
    assert_raises(ArgumentError) { @workspace.filter_problems(severity: 5) }
    assert_raises(ArgumentError) { @workspace.filter_problems(source: :unknown) }
    assert_raises(ArgumentError) { @workspace.filter_problems(text: "x" * 4_097) }

    uri = Sadr::Protocol.uri(File.join(@root, "missing.rb"))
    @workspace.diagnostics.publish(:test, uri, [diagnostic("missing")])
    entry = @workspace.diagnostics.for_uri(uri).first
    refute @workspace.send(:select_problem, entry)
    assert_match(/not a file/, @workspace.message)
  end

  def test_filtering_keeps_each_problem_node_identity_stable
    @workspace.diagnostics.publish(:task, @uri,
      [diagnostic("first"), diagnostic("second")])
    ids = tree_source.first[:children].to_h do |node|
      [node[:value].diagnostic.fetch("message"), node[:id]]
    end

    @workspace.filter_problems(text: "second")

    assert_equal ids.fetch("second"), tree_source.first[:children].first[:id]
  end

  def test_background_publications_update_the_tree_on_the_ui_queue
    window = Object.new
    window.define_singleton_method(:request_frame) {}
    @workspace.window = window
    assert_empty tree_source

    Thread.new do
      @workspace.diagnostics.publish(:task, @uri, [diagnostic("background")])
    end.join

    assert_empty tree_source
    @workspace.drain
    assert_equal ["error [task] 1: background"], tree_source.first[:children].map { |node| node[:label] }
  end

  def test_status_bar_reports_error_and_warning_counts
    @workspace.diagnostics.publish(:task, @uri,
      [diagnostic("error"), diagnostic("warning", severity: 2)])
    window = Zaniah::Platform.open_window(backend: :headless, width: 800, height: 300)
    window.text_system = Zaniah::TextSystem::Renderer.new
    controller = Canopus::Controller.new(@workspace, window)
    window.render(controller.view)

    assert window.text_runs.any? { |run| run[2].include?("E1 W1 ruby") }
  ensure
    window&.on_close { true }
    window&.close
  end
end
