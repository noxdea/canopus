# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "prism"
require "open3"
require "rbconfig"

class TestRunnerTest < Minitest::Test
  class ExecutionTerminal
    Status = Struct.new(:success?)
    attr_reader :options

    def initialize(**options)
      @options, @output, @alive = options, +"".b, true
    end

    def read(max_bytes:, max_seconds:)
      return nil if !@alive && @output.empty?

      @output.slice!(0, max_bytes).to_s
    end

    def pending? = !@output.empty?
    def alive? = @alive
    def status = @alive ? nil : Status.new(@success)
    def close = (@alive = false)
    def resize(columns:, rows:) = nil
    def signal(_name) = (@alive = false)

    def finish(output, success:)
      @output << output
      @success, @alive = success, false
    end
  end

  class RefreshDiscovery
    attr_reader :calls, :maximum_active

    def initialize(result)
      @result = result
      @calls = @active = @maximum_active = 0
      @lock = Mutex.new
    end

    def discover(cancelled:)
      call = @lock.synchronize do
        @calls += 1
        @active += 1
        @maximum_active = [@maximum_active, @active].max
        @calls
      end
      if call == 1
        sleep 0.001 until cancelled.call
        []
      else
        @result
      end
    ensure
      @lock.synchronize { @active -= 1 }
    end
  end

  class BlockingDiscovery
    def discover(cancelled:)
      sleep 0.001 until cancelled.call
      []
    end
  end

  def setup
    @root = Dir.mktmpdir("canopus-tests-")
  end

  def teardown
    @workspace&.close
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def test_minitest_and_rspec_adapters_extract_only_ast_test_declarations
    write("test/user_test.rb", <<~RUBY)
      # def test_from_comment; end
      FAKE = "test 'from string' do"
      class UserTest < ApplicationTestCase
        def test_valid
        end

        def self.test_class_method
        end

        class << self
          def test_singleton_method
          end
        end

        test "日本語の例" do
        end

        it "class it is not a test" do
        end

        def helper
          it "not a test" do
          end
          helper.test "also not a test" do
          end
        end
      end

      describe "calculator" do
        it "adds" do
        end
        test "spec test is not a test" do
        end
      end
    RUBY
    write("spec/widget_spec.rb", <<~RUBY)
      # it "from comment"
      FAKE = "describe 'from string'"
      RSpec.describe Widget do
        context "when ready" do
          it "works" do
          end
          specify :pending

          def helper
            it "not an example" do
            end
          end
          helper.context "not a group" do
            it "also not an example" do
            end
          end
        end
      end
    RUBY

    tests = discovery.discover

    assert_equal %i[rspec rspec minitest minitest minitest], tests.map(&:framework)
    assert_equal ["works", "pending", "test_valid", "日本語の例", "adds"], tests.map(&:name)
    assert_equal [["Widget", "when ready"], ["Widget", "when ready"],
      ["UserTest"], ["UserTest"], ["calculator"]], tests.map(&:groups)
    assert_equal [5, 7, 4, 15, 30], tests.map(&:line)
    assert_equal ["Widget when ready works", "Widget when ready pending",
      "test_valid", "test_日本語の例", "test_0001_adds"],
      tests.map(&:selector)
    assert tests.all?(&:frozen?)
    assert tests.all? { |test| test.groups.frozen? && test.name.frozen? && test.path.frozen? }
  end

  def test_discovery_obeys_ignore_and_rejects_untrusted_files
    write(".gitignore", "ignored/\n")
    write("ignored/hidden_test.rb", "class Hidden; def test_hidden; end; end\n")
    write("plain.rb", "class Plain; def test_not_a_candidate; end; end\n")
    write("test/nonstandard.rb", "class Nonstandard; def test_found; end; end\n")
    write("broken_test.rb", "class Broken <\n")
    write(".hidden/visible_spec.rb", "describe('hidden') { it('works') {} }\n")
    write("test/oversized_test.rb", "describe('group') { it(#{('x' * 4_097).inspect}) {} }\n")
    File.binwrite(File.join(@root, "invalid_test.rb"), "class Bad; def test_\xFF; end; end".b)
    unless Gem.win_platform?
      begin
        File.binwrite(File.join(@root.b, "invalid_\xFF_test.rb".b), "class InvalidName; def test_bad; end; end\n")
      rescue Errno::EPERM
        # Some macOS volumes reject byte-invalid filenames.
      end
    end
    File.binwrite(File.join(@root, "large_test.rb"), " " * (Canopus::TestRunner::Discovery::MAX_FILE_BYTES + 1))
    unless Gem.win_platform?
      outside = File.join(Dir.mktmpdir("canopus-tests-outside-"), "outside_test.rb")
      File.write(outside, "class Outside; def test_secret; end; end\n")
      File.symlink(outside, File.join(@root, "linked_test.rb"))
    end

    tests = discovery.discover

    assert_equal ["works", "test_found"], tests.map(&:name)
    assert_equal [".hidden/visible_spec.rb", "test/nonstandard.rb"], tests.map(&:path)
  ensure
    FileUtils.remove_entry(File.dirname(outside)) if outside && File.exist?(File.dirname(outside))
  end

  def test_minitest_scope_and_rspec_aliases_are_classified_from_the_ast
    write("test/scope_test.rb", <<~RUBY)
      class ScopeTest
        def test_instance; end
        def self.test_singleton; end
        class << self
          def test_eigenclass; end
        end
        test "class dsl" do end
        it "wrong class dsl" do end
      end
      describe "spec group" do
        it "spec dsl" do end
        specify "specified" do end
        test "wrong spec dsl" do end
      end
    RUBY
    write("spec/aliases_spec.rb", <<~RUBY)
      ::RSpec.describe "aliases" do
        fspecify "focused specify" do end
        focus "focused" do end
        skip "skipped"
      end
    RUBY

    tests = discovery.discover

    assert_equal ["focused specify", "focused", "skipped", "test_instance", "class dsl", "spec dsl", "specified"],
      tests.map(&:name)
    assert_equal %i[rspec rspec rspec minitest minitest minitest minitest], tests.map(&:framework)
  end

  def test_static_selectors_match_runtime_descriptions_and_skip_dynamic_example_names
    write("spec/descriptions_spec.rb", <<~RUBY)
      NAME = "dynamic"
      RSpec.describe ::String, "#empty?", type: :model do
        it NAME do end
        it "works" do end
      end
      RSpec.describe "first", "second", :slow do
        specify :runs do end
      end
      RSpec.describe "" do
        it "cannot be selected exactly" do end
      end
    RUBY
    write("test/descriptions_test.rb", <<~RUBY)
      NAME = "dynamic"
      describe ::String do
        it NAME do end
        it "works" do end
      end
      class NameTest
        test NAME do end
        test "runs" do end
      end
    RUBY

    tests = discovery.discover

    assert_equal ["works", "runs", "works", "runs"], tests.map(&:name)
    assert_equal ["String#empty? works", "first second runs", "test_0002_works", "test_runs"],
      tests.map(&:selector)
    assert_equal [["String#empty?"], ["first second"], ["String"], ["NameTest"]], tests.map(&:groups)
  end

  def test_minitest_keeps_module_scope_for_an_exact_runtime_filter
    write("test/namespaced_test.rb", <<~RUBY)
      module Admin
        class UserTest
          def test_same; end
        end
      end
      class UserTest
        def test_same; end
      end
      class ::RootTest
        def test_root; end
      end
    RUBY

    tests = discovery.discover

    assert_equal [["Admin", "UserTest"], ["UserTest"], ["RootTest"]], tests.map(&:groups)
    filters = tests.map { |test| Canopus::TestRunner::Execution.task(test, root: @root)["command"].last }
    assert_equal ["/\\AAdmin::UserTest#test_same\\z/", "/\\AUserTest#test_same\\z/",
      "/\\ARootTest#test_root\\z/"], filters
  end

  def test_rspec_nested_module_description_runs_with_the_exact_filter
    path = "spec/nested_spec.rb"
    write(path, <<~RUBY)
      RSpec.describe ::String do
        describe "#empty?" do
          it("works") {}
        end
      end
    RUBY
    test = discovery.discover.first

    assert_equal "String#empty? works", test.selector
    command = Canopus::TestRunner::Execution.task(test, root: @root)["command"]
    output, error, status = Open3.capture3(*command, chdir: @root)

    assert status.success?, error
    assert_match(/\n1 example, 0 failures/, output)
  end

  def test_minitest_selectors_follow_each_runtime_spec_suite
    write("test/spec_selectors_test.rb", <<~RUBY)
      dynamic = "dynamic"
      describe "calc" do
        it "first" do end
      end
      describe "calc" do
        it dynamic do end
        it do end
        it "second" do end
      end
      describe "calc", :unit do
        specify "works"
      end
    RUBY

    tests = discovery.discover

    assert_equal ["first", "second", "works"], tests.map(&:name)
    assert_equal [["calc"], ["calc"], ["calc::unit"]], tests.map(&:groups)
    assert_equal ["test_0001_first", "test_0003_second", "test_0001_works"], tests.map(&:selector)
  end

  def test_minitest_describe_ignores_an_ordinary_module_namespace
    write("test/module_spec_test.rb", <<~RUBY)
      module Admin
        describe "calc" do
          it "works" do end
        end
      end
      class DirectSpec < Minitest::Spec
        it "direct" do end
        describe "nested" do
          it "works" do end
        end
      end
    RUBY

    tests = discovery.discover

    assert_equal [["calc"], ["DirectSpec"], ["DirectSpec", "nested"]], tests.map(&:groups)
    filters = tests.map { |test| Canopus::TestRunner::Execution.task(test, root: @root)["command"].last }
    assert_equal ["/\\Acalc#test_0001_works\\z/", "/\\ADirectSpec#test_0001_direct\\z/",
      "/\\ADirectSpec::nested#test_0001_works\\z/"], filters
  end

  def test_minitest_filter_runs_only_the_selected_suite
    write("test/exact_test.rb", <<~RUBY)
      require "minitest/autorun"
      class FirstTest < Minitest::Test
        def test_same; assert true; end
      end
      class SecondTest < Minitest::Test
        def test_same; assert true; end
      end
    RUBY
    test = Canopus::TestRunner::Test.new(:minitest, "test/exact_test.rb", "test_same",
      ["SecondTest"].freeze, 5, 0, 0, "test_same")
    command = Canopus::TestRunner::Execution.task(test, root: @root)["command"]

    output, error, status = Open3.capture3(*command, chdir: @root)

    assert status.success?, error
    assert_match(/\n1 runs?/, output)
    refute_match(/\n2 runs?/, output)
  end

  def test_ambiguous_test_and_spec_directories_select_one_adapter
    write("test/spec/example.rb", "describe('rspec') { it('one') {} }\n")
    write("spec/test/example.rb", "class Example; def test_one; end; end\n")

    tests = discovery.discover

    assert_equal [["spec/test/example.rb", :minitest], ["test/spec/example.rb", :rspec]],
      tests.map { |test| [test.path, test.framework] }
    assert_equal 2, tests.length
  end

  def test_ignore_boundary_skips_invalid_filenames_before_delegate
    write("test/valid_test.rb", "class Valid; def test_valid; end; end\n")
    delegate = Object.new
    calls = 0
    delegate.define_singleton_method(:ignored?) do |path, directory: false|
      calls += 1
      raise ArgumentError, "invalid path" unless path.valid_encoding?
      false
    end
    boundary = Canopus::TestRunner::BoundedIgnore.new(@root, delegate: delegate)
    assert boundary.ignored?("bad_\xFF_test.rb".b)
    assert_equal 0, calls

    unless Gem.win_platform?
      begin
        File.binwrite(File.join(@root.b, "bad_\xFF_test.rb".b), "class Bad; def test_bad; end; end\n")
      rescue Errno::EPERM
        # The boundary itself remains covered when the volume rejects this filename.
      end
    end

    assert_equal ["test_valid"], discovery(ignore: delegate).discover.map(&:name)
  end

  def test_bounded_ignore_loading_honors_cancellation
    100.times do |index|
      write("tree/#{index}/.gitignore", "ignored/\n")
      write("tree/#{index}/test/example_test.rb", "class Example; def test_one; end; end\n")
    end
    calls = 0
    stopped = false

    tests = discovery.discover(cancelled: lambda {
      calls += 1 unless stopped
      stopped = calls > 40
    })

    assert_equal 41, calls
    assert_operator tests.length, :<, 100
  end

  def test_git_worktree_common_exclude_is_loaded_within_its_resolved_directory
    common = Dir.mktmpdir("canopus-common-git-")
    git_directory = File.join(common, "worktrees", "one")
    FileUtils.mkdir_p(File.join(common, "info"))
    FileUtils.mkdir_p(git_directory)
    File.write(File.join(git_directory, "commondir"), "../..\n")
    File.write(File.join(common, "info", "exclude"), "ignored/\n")
    write(".git", "gitdir: #{git_directory}\n")
    write("ignored/hidden_test.rb", "class Hidden; def test_hidden; end; end\n")
    write("test/example_test.rb", "class Example; def test_one; end; end\n")

    assert_equal ["test_one"], discovery.discover.map(&:name)
  ensure
    FileUtils.remove_entry(common) if common && File.exist?(common)
  end

  def test_linked_worktree_exclude_symlink_is_not_followed
    skip "symlinks unavailable" if Gem.win_platform?

    common = Dir.mktmpdir("canopus-common-git-")
    outside = Dir.mktmpdir("canopus-outside-ignore-")
    FileUtils.mkdir_p(File.join(common, "info"))
    File.write(File.join(outside, "exclude"), "ignored/\n")
    File.symlink(File.join(outside, "exclude"), File.join(common, "info", "exclude"))
    write(".git", "gitdir: #{common}\n")
    write("ignored/visible_test.rb", "class Visible; def test_visible; end; end\n")

    assert_equal ["test_visible"], discovery.discover.map(&:name)
  ensure
    FileUtils.remove_entry(common) if common && File.exist?(common)
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_public_test_runner_require_is_self_contained
    env = {"ALKAID_PATH" => ENV["ALKAID_PATH"]}
    script = "require 'canopus/test_runner'; abort unless Canopus::TestRunner::Discovery"
    _output, error, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-e", script,
      chdir: File.expand_path("..", __dir__))

    assert status.success?, error
  end

  def test_discovery_is_cancellable_and_adapter_output_is_bounded
    write("test/many_test.rb", <<~RUBY)
      class ManyTest
        #{100.times.map { |index| "def test_#{index}; end" }.join("\n  ")}
      end
    RUBY
    adapter = Canopus::TestRunner::Minitest.new
    parsed = Prism.parse(File.read(File.join(@root, "test/many_test.rb")))

    assert_empty discovery.discover(cancelled: -> { true })
    assert_equal 3, adapter.discover(parsed.value, path: "test/many_test.rb", limit: 3,
      cancelled: -> { false }).length
  end

  def test_discovery_centrally_caps_and_validates_custom_adapter_results
    write("test/custom_test.rb", "class Custom; end\n")
    path = "test/custom_test.rb".freeze
    test = Canopus::TestRunner::Test.new(:minitest, path, "test_custom".freeze,
      ["Custom".freeze].freeze, 1, 0, 0, "test_custom".freeze)
    greedy = Object.new
    greedy.define_singleton_method(:candidate?) { |_| true }
    greedy.define_singleton_method(:discover) do |_root, path:, limit:, cancelled:|
      Array.new(limit + 1, test)
    end

    tests = Canopus::TestRunner::Discovery.new(root: @root, adapters: [greedy]).discover
    assert_equal Canopus::TestRunner::Discovery::MAX_TESTS, tests.length

    invalid = Object.new
    invalid.define_singleton_method(:candidate?) { |_| true }
    invalid.define_singleton_method(:discover) do |_root, path:, limit:, cancelled:|
      [Object.new, test]
    end
    assert_equal [test], Canopus::TestRunner::Discovery.new(root: @root, adapters: [invalid]).discover
  end

  def test_discovery_rejects_invalid_collaborators
    adapter = Canopus::TestRunner::Minitest.new
    rspec = Canopus::TestRunner::RSpec.new
    refute adapter.candidate?("test/example_spec.rb")
    refute rspec.candidate?("spec/example_test.rb")
    assert adapter.candidate?("spec/example_test.rb")
    assert rspec.candidate?("test/example_spec.rb")
    assert_equal :rspec, Canopus::TestRunner.framework_for("test/spec/example.rb")
    assert_equal :minitest, Canopus::TestRunner.framework_for("spec/test/example.rb")
    assert_raises(ArgumentError) { Canopus::TestRunner::Discovery.new(root: @root, ignore: Object.new) }
    assert_raises(ArgumentError) { Canopus::TestRunner::Discovery.new(root: @root, adapters: []) }
    assert_raises(ArgumentError) do
      Canopus::TestRunner::Discovery.new(root: @root,
        adapters: Array.new(Canopus::TestRunner::Discovery::MAX_ADAPTERS + 1, adapter))
    end
    assert_raises(ArgumentError) { discovery.discover(cancelled: Object.new) }
  end

  def test_test_tree_bounds_labels_before_joining_large_groups
    group = ("x" * 4_096).freeze
    groups = Array.new(32, group).freeze
    tests = 10_000.times.map do |index|
      Canopus::TestRunner::Test.new(:minitest, "test/stress_test.rb".freeze, "test_#{index}".freeze,
        groups, index + 1, 0, index, "test_#{index}".freeze)
    end.freeze
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.instance_variable_set(:@tests, tests)

    nodes = @workspace.send(:test_nodes)

    assert_equal 10_000, nodes.first[:children].length
    assert nodes.first[:children].all? { |node| node[:label].length <= 200 }
  end

  def test_workspace_discovery_does_not_build_project_ignore_matcher
    write("test/example_test.rb", "class Example; def test_one; end; end\n")
    @workspace = Canopus::Workspace.new(root: @root)
    project = @workspace.instance_variable_get(:@project)
    project.define_singleton_method(:ignore_matcher) { raise "unbounded ignore load" }

    @workspace.test_tree
    wait_for_discovery

    assert_equal ["test_one"], @workspace.tests.map(&:name)
  end

  def test_workspace_discovers_displays_refreshes_and_navigates_tests
    write("test/example_test.rb", <<~RUBY)
      class ExampleTest
        def test_one; end
      end
    RUBY
    @workspace = Canopus::Workspace.new(root: @root)
    tree = @workspace.test_tree
    assert @workspace.test_discovery_pending?
    wait_for_discovery

    assert_equal ["test_one"], @workspace.tests.map(&:name)
    assert_equal 1, @workspace.panels.fetch("test").badge
    source = tree.instance_variable_get(:@source)
    assert_equal ["test/example_test.rb"], source.map { |node| node[:label] }
    assert_equal ["▶ ExampleTest › test_one · line 2"], source.first[:children].map { |node| node[:label] }

    refute @workspace.panels.visible?("test")
    @workspace.call("panel.test")
    assert @workspace.panels.visible?("test")
    assert @workspace.send(:select_test, @workspace.tests.first)
    assert_equal File.realpath(File.join(@root, "test/example_test.rb")), @workspace.editor.buffer.path
    assert_equal 1, @workspace.editor.buffer.rope.point_at(@workspace.editor.primary.head).row

    write("test/example_test.rb", "class ExampleTest\n  def test_two; end\nend\n")
    @workspace.call("test.refresh")
    wait_for_discovery
    assert_equal ["test_two"], @workspace.tests.map(&:name)
  end

  def test_execution_builds_argument_only_commands_and_classifies_bounded_results
    write("test/example_test.rb", "class ExampleTest; def test_one; end; end\n")
    minitest = Canopus::TestRunner::Test.new(:minitest, "test/example_test.rb", "test_one; touch owned",
      ["ExampleTest"].freeze, 1, 19, 19, "test_one; touch owned")

    task = Canopus::TestRunner::Execution.task(minitest, root: @root)

    assert_equal RbConfig.ruby, task["command"].first
    assert_equal "test/example_test.rb", task["command"][2]
    assert_equal "/\\AExampleTest##{Regexp.escape(minitest.name)}\\z/", task["command"].last
    assert_equal "silent", task.dig("presentation", "reveal")
    assert task["env"].is_a?(Hash)

    execution = Canopus::TestRunner::Execution.new(minitest, Object.new)
    execution.append("1 runs, 1 assertions, 0 failures, 0 errors, 1 skips\n")
    assert_equal :skipped, execution.finish(ExecutionTerminal::Status.new(true)).status

    execution = Canopus::TestRunner::Execution.new(minitest, Object.new)
    execution.append("1 runs, 0 assertions, 0 failures, 0 errors, 1 skips\n" \
      "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips\n")
    assert_equal :success, execution.finish(ExecutionTerminal::Status.new(true)).status

    rspec_result = Canopus::TestRunner::Test.new(:rspec, "spec/example_spec.rb", "works",
      ["example"].freeze, 1, 0, 0, "example works")
    execution = Canopus::TestRunner::Execution.new(rspec_result, Object.new)
    execution.append("1 example, 0 failures, 1 pending\n1 example, 0 failures\n")
    assert_equal :success, execution.finish(ExecutionTerminal::Status.new(true)).status

    execution = Canopus::TestRunner::Execution.new(rspec_result, Object.new)
    execution.append("0 examples, 0 failures\n")
    assert_equal :failure, execution.finish(ExecutionTerminal::Status.new(true)).status

    another = rspec_result.with(name: "second", selector: "example second")
    execution = Canopus::TestRunner::Execution.new(rspec_result, Object.new, tests: [rspec_result, another])
    execution.append("1 example, 0 failures\n")
    assert_equal :failure, execution.finish(ExecutionTerminal::Status.new(true)).status

    execution = Canopus::TestRunner::Execution.new(rspec_result, Object.new, tests: [rspec_result, another])
    execution.append("2 examples, 0 failures, 1 pending\n")
    assert_equal :success, execution.finish(ExecutionTerminal::Status.new(true)).status

    execution = Canopus::TestRunner::Execution.new(minitest, Object.new)
    execution.append("x" * Canopus::TestRunner::Execution::MAX_OUTPUT_BYTES)
    execution.append("Failure:\n#{File.join(@root, minitest.path)}:1: broken\n")
    result = execution.finish(ExecutionTerminal::Status.new(false))
    assert_equal [:failure, minitest.path, 1], [result.status, result.path, result.line]

    write("Gemfile", "source 'https://rubygems.org'\n")
    write("spec/example_spec.rb", "RSpec.describe('example') { it('works') {} }\n")
    rspec = Canopus::TestRunner::Test.new(:rspec, "spec/example_spec.rb", "works",
      ["example"].freeze, 1, 28, 28, "example works")
    bundled = Canopus::TestRunner::Execution.task(rspec, root: @root)
    assert_equal [RbConfig.ruby, "-S", "bundle", "exec", RbConfig.ruby, "-S", "rspec"],
      bundled["command"].first(7)
    assert_equal ["spec/example_spec.rb:1", "--example-matches", "\\Aexample\\ works\\z"],
      bundled["command"][7, 3]
    assert_equal File.join(File.realpath(@root), "Gemfile"), bundled["env"]["BUNDLE_GEMFILE"]

    write("other/example_test.rb", "class ExampleTest; def test_one; end; end\n")
    other = minitest.with(path: "other/example_test.rb")
    refute_equal task["label"], Canopus::TestRunner::Execution.task(other, root: @root)["label"]
  end

  def test_rspec_combined_selectors_have_a_process_safe_bound
    path = "spec/example_spec.rb"
    write(path, "RSpec.describe('example') { it('works') {} }\n")
    selector = "x" * 100
    tests = 100.times.map do |index|
      Canopus::TestRunner::Test.new(:rspec, path, "test #{index}", ["example"].freeze,
        1, index, index, "#{selector} #{index}")
    end

    error = assert_raises(Canopus::Error) do
      Canopus::TestRunner::Execution.task(tests.first, root: @root, tests: tests)
    end
    assert_match(/selectors are too large/, error.message)
  end

  def test_failure_line_outside_the_current_file_falls_back_to_the_declaration
    path = "test/example_test.rb"
    write(path, "class ExampleTest; def test_one; end; end\n")
    test = Canopus::TestRunner::Test.new(:minitest, path, "test_one", ["ExampleTest"].freeze,
      1, 19, 19, "test_one")
    execution = Canopus::TestRunner::Execution.new(test, Object.new)
    @workspace = Canopus::Workspace.new(root: @root)
    result = Canopus::TestRunner::Result.new(:failure, path, 999, "failed").freeze

    normalized = @workspace.send(:normalize_test_result, execution, result)

    assert_equal 1, normalized.line
  end

  def test_gutter_runs_tests_and_failure_results_navigate_and_publish_diagnostics
    path = "test/example_test.rb"
    write(path, <<~RUBY)
      class ExampleTest
        def test_one
          assert false
        end
      end
    RUBY
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.test_tree
    wait_for_discovery
    editor = @workspace.open(File.join(@root, path))
    previous = @workspace.task_runner
    terminals = []
    runner = Canopus::Task::Runner.new(scrollback: 50, queue_limit_bytes: 65_536,
      terminal_factory: ->(**options) { ExecutionTerminal.new(**options).tap { |terminal| terminals << terminal } })
    @workspace.instance_variable_set(:@task_runner, runner)
    previous.close

    gutter = @workspace.decorations.items_for(editor.buffer, 0...editor.buffer.line_count, context: editor)
      .find { |item| item.source == :test }
    assert_equal 1, gutter.row
    assert_equal :muted, gutter.style[:color]

    gutter.on_click.call(editor, gutter.row)
    test = @workspace.tests.first
    assert_equal :running, @workspace.test_results.fetch(test).status
    assert_equal [RbConfig.ruby, "-Itest", path, "--name", "/\\AExampleTest#test_one\\z/"],
      terminals.first.options[:command]

    terminals.first.finish("Failure:\n#{path}:3: Expected false to be truthy.\n", success: false)
    wait_until do
      @workspace.drain_task_outputs
      @workspace.test_results[test]&.status == :failure
    end

    result = @workspace.test_results.fetch(test)
    assert_equal [path, 3], [result.path, result.line]
    assert_equal [:test], @workspace.diagnostics.all(source: :test).map(&:source)
    failed = @workspace.decorations.items_for(editor.buffer, 0...editor.buffer.line_count, context: editor)
      .find { |item| item.source == :test }
    assert_equal :error, failed.style[:color]
    assert @workspace.send(:select_test, test)
    assert_equal 2, @workspace.editor.buffer.rope.point_at(@workspace.editor.primary.head).row
    assert_match(/×/, @workspace.send(:test_case_label, test))
  end

  def test_same_line_rspec_examples_share_one_filtered_execution
    path = "spec/example_spec.rb"
    write(path, 'RSpec.describe "example" do; it("one") {}; it("two") {}; end' + "\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.test_tree
    wait_for_discovery
    editor = @workspace.open(File.join(@root, path))
    previous = @workspace.task_runner
    terminals = []
    runner = Canopus::Task::Runner.new(scrollback: 50, queue_limit_bytes: 65_536,
      terminal_factory: ->(**options) { ExecutionTerminal.new(**options).tap { |terminal| terminals << terminal } })
    @workspace.instance_variable_set(:@task_runner, runner)
    previous.close

    gutter = @workspace.decorations.items_for(editor.buffer, 0...1, context: editor)
      .find { |item| item.source == :test }
    gutter.on_click.call(editor, 0)

    assert_equal 1, terminals.length
    assert_equal "#{path}:1", terminals.first.options[:command][3]
    command = terminals.first.options[:command]
    filters = command.each_index.filter_map { |index| command[index + 1] if command[index] == "--example-matches" }
    assert_equal ["\\Aexample\\ one\\z", "\\Aexample\\ two\\z"], filters
    assert_equal [:running, :running], @workspace.tests.map { |test| @workspace.test_results.fetch(test).status }
    @workspace.run_test(@workspace.tests.last)
    assert_equal 2, terminals.length
    assert_equal [:skipped, :running], @workspace.tests.map { |test| @workspace.test_results.fetch(test).status }
    terminals.last.finish("1 example, 0 failures\n", success: true)
    wait_until do
      @workspace.drain_task_outputs
      @workspace.test_results[@workspace.tests.last]&.status == :success
    end
    assert_equal [:skipped, :success], @workspace.tests.map { |test| @workspace.test_results.fetch(test).status }
  end

  def test_result_from_an_older_discovery_generation_is_ignored
    path = "test/example_test.rb"
    write(path, "class ExampleTest; def test_one; end; end\n")
    test = Canopus::TestRunner::Test.new(:minitest, path, "test_one", ["ExampleTest"].freeze, 1, 19, 19,
      "test_one")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.instance_variable_set(:@tests, [test].freeze)
    @workspace.instance_variable_set(:@test_generation, 2)
    terminal = ExecutionTerminal.new
    terminal.finish("Failure:\n#{path}:1: stale\n", success: false)
    output = Canopus::Task::Runner::Output.new(999, "old", terminal,
      {"panel" => "output", "reveal" => "silent"}.freeze).freeze
    execution = Canopus::TestRunner::Execution.new(test, output, generation: 1)
    execution.append("Failure:\n#{path}:1: stale\n")
    @workspace.instance_variable_get(:@test_executions)[output.id] = execution
    @workspace.instance_variable_get(:@test_outputs)[test] = output

    @workspace.send(:complete_test_output, output)

    assert_empty @workspace.test_results
  end

  def test_refresh_coalesces_to_one_discovery_worker
    path = "test/example_test.rb"
    write(path, "class ExampleTest; def test_one; end; end\n")
    test = Canopus::TestRunner::Test.new(:minitest, path.freeze, "test_one".freeze,
      ["ExampleTest".freeze].freeze, 1, 19, 19, "test_one".freeze)
    fake = RefreshDiscovery.new([test].freeze)
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.instance_variable_set(:@test_discovery, fake)

    @workspace.test_tree
    @workspace.refresh_tests
    wait_for_discovery

    assert_equal 2, fake.calls
    assert_equal 1, fake.maximum_active
    assert_equal [test], @workspace.tests
  end

  def test_close_cancels_and_joins_discovery
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.instance_variable_set(:@test_discovery, BlockingDiscovery.new)
    @workspace.test_tree
    wait_until { @workspace.instance_variable_get(:@test_discovery_thread)&.alive? }

    thread = @workspace.instance_variable_get(:@test_discovery_thread)
    @workspace.close
    @workspace = nil

    refute thread.alive?
  end

  def test_navigation_rejects_a_test_replaced_by_a_symlink
    skip "symlinks unavailable" if Gem.win_platform?

    path = "test/example_test.rb"
    write(path, "class ExampleTest; def test_one; end; end\n")
    outside_root = Dir.mktmpdir("canopus-tests-outside-")
    outside = File.join(outside_root, "outside.rb")
    File.write(outside, "puts :outside\n")
    @workspace = Canopus::Workspace.new(root: @root)
    @workspace.test_tree
    wait_for_discovery
    test = @workspace.tests.first
    File.unlink(File.join(@root, path))
    File.symlink(outside, File.join(@root, path))

    refute @workspace.send(:select_test, test)
    assert_match(/not a file/, @workspace.message)
  ensure
    FileUtils.remove_entry(outside_root) if outside_root && File.exist?(outside_root)
  end

  private

  def discovery(ignore: nil)
    Canopus::TestRunner::Discovery.new(root: @root, ignore: ignore)
  end

  def write(relative, contents)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def wait_for_discovery
    wait_until do
      @workspace.drain
      !@workspace.test_discovery_pending?
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end
end
