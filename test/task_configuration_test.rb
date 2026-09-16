# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class TaskConfigurationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-task-")
    FileUtils.mkdir_p(File.join(@root, ".canopus"))
  end

  def teardown
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def test_loads_jsonc_and_expands_bounded_context
    source = File.join(@root, "lib", "example.rb")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, "puts :ok\n")
    write_tasks(<<~JSONC)
      {
        // Commands are argv, never shell source.
        "tasks": [{
          "label": "test",
          "command": ["ruby", "${file}", "--line=${lineNumber}", "${selectedText}", "${env:TOKEN}"],
          "cwd": "${workspaceFolder}",
          "problem_matcher": "ruby",
          "presentation": {"panel": "output", "reveal": "always"},
        }],
      }
    JSONC
    token = +"secret"
    configuration = Canopus::Task::Configuration.new(root: @root, environment: {"TOKEN" => token})
    token.replace("changed")
    resolved = configuration.resolve("test", file: source, line_number: 7, selected_text: "日本")

    assert_equal ["ruby", File.realpath(source), "--line=7", "日本", "secret"], resolved["command"]
    assert_equal configuration.root, resolved["cwd"]
    assert_equal "ruby", resolved["problem_matcher"]
    assert resolved.frozen?
    assert resolved["command"].all?(&:frozen?)
    assert configuration.tasks.first.frozen?
  end

  def test_missing_file_is_an_empty_frozen_list
    configuration = Canopus::Task::Configuration.new(root: @root, environment: {})
    assert_empty configuration.tasks
    assert configuration.tasks.frozen?
  end

  def test_rejects_unknown_missing_and_malformed_variables
    {
      "${file}" => /file is unavailable/,
      "${lineNumber}" => /lineNumber is unavailable/,
      "${selectedText}" => /selectedText is unavailable/,
      "${env:MISSING}" => /environment variable MISSING is unavailable/,
      "${unknown}" => /unknown task variable/,
      "${file" => /malformed task variable/
    }.each do |value, message|
      write_tasks(JSON.generate("tasks" => [task("Case", ["ruby", value])]))
      error = assert_raises(Canopus::Error) { loader.resolve("Case") }
      assert_match message, error.message
    end
  end

  def test_replacement_text_is_not_reexpanded_and_expansion_is_bounded
    write_tasks(JSON.generate("tasks" => [task("Literal", ["ruby", "${env:LITERAL}", "${selectedText}"])]))
    resolved = loader("LITERAL" => "${file}").resolve("Literal", selected_text: "${env:MISSING}")
    assert_equal ["ruby", "${file}", "${env:MISSING}"], resolved["command"]

    large = "x" * (600 * 1024)
    write_tasks(JSON.generate("tasks" => [task("Large", ["ruby", "${env:LARGE}", "${env:LARGE}"])]))
    assert_raises(Canopus::Error) { loader("LARGE" => large).resolve("Large") }
  end

  def test_rejects_unsafe_configuration_and_working_directory_paths
    write_tasks(JSON.generate("tasks" => [task("Escape", ["ruby"], "cwd" => "${workspaceFolder}/..")]))
    assert_match(/outside the workspace/, assert_raises(Canopus::Error) { loader.resolve("Escape") }.message)

    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    outside = Dir.mktmpdir("canopus-task-outside-")
    begin
      FileUtils.rm_f(File.join(@root, ".canopus", "tasks.jsonc"))
      File.write(File.join(outside, "tasks.jsonc"), JSON.generate("tasks" => []))
      File.symlink(File.join(outside, "tasks.jsonc"), File.join(@root, ".canopus", "tasks.jsonc"))
      assert_raises(Canopus::Error) { loader }
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  def test_validates_shape_limits_unique_labels_and_presentation
    invalid = [
      [],
      {"tasks" => {}},
      {"tasks" => [task("")]},
      {"tasks" => [task("Bad", [])]},
      {"tasks" => [task("Bad", [1])]},
      {"tasks" => [task("Bad", ["ruby"], "cwd" => 1)]},
      {"tasks" => [task("Bad", ["ruby"], "presentation" => {"panel" => "terminal"})]},
      {"tasks" => [task("Bad", ["ruby"], "presentation" => {"reveal" => "sometimes"})]},
      {"tasks" => [task("Same"), task("Same")]},
      {"tasks" => Array.new(129) { |index| task("Run #{index}") }}
    ]
    invalid.each do |document|
      write_tasks(JSON.generate(document))
      assert_raises(Canopus::Error) { loader }
    end

    File.binwrite(File.join(@root, ".canopus", "tasks.jsonc"), "{\"tasks\":[]}" + (" " * 1_048_577))
    assert_raises(Canopus::Error) { loader }
    File.binwrite(File.join(@root, ".canopus", "tasks.jsonc"), "\xff".b)
    assert_raises(Canopus::Error) { loader }
  end

  def test_resolve_requires_the_original_entry_or_label
    write_tasks(JSON.generate("tasks" => [task("Named")]))
    configuration = loader
    assert_equal "Named", configuration.resolve("Named")["label"]
    assert_raises(Canopus::Error) { configuration.resolve(task("Named")) }
  end

  def test_revalidates_expanded_labels_and_rejects_context_collisions
    write_tasks(JSON.generate("tasks" => [task("${env:FIRST}"), task("${env:SECOND}")]))
    assert_match(/must be unique/, assert_raises(Canopus::Error) do
      loader("FIRST" => "same", "SECOND" => "same").resolve("${env:FIRST}")
    end.message)

    write_tasks(JSON.generate("tasks" => [task("${env:LABEL}")]))
    [" bad", "bad\nlabel", "x" * 257].each do |label|
      assert_match(/invalid expanded task label/, assert_raises(Canopus::Error) do
        loader("LABEL" => label).resolve("${env:LABEL}")
      end.message)
    end

    write_tasks(JSON.generate("tasks" => [task("empty", ["${env:COMMAND}"])]))
    assert_match(/executable must not be empty/, assert_raises(Canopus::Error) do
      loader("COMMAND" => "").resolve("empty")
    end.message)
  end

  def test_resolve_shares_one_expansion_budget_across_labels_and_task
    prefix = "p" * 200
    large = "x" * 1_030_000
    tasks = Array.new(128) do |index|
      command = index.zero? ? ["ruby", "${env:LARGE}"] : ["ruby"]
      task("${env:PREFIX}-#{index}", command)
    end
    write_tasks(JSON.generate("tasks" => tasks))

    error = assert_raises(Canopus::Error) do
      loader("PREFIX" => prefix, "LARGE" => large).resolve(tasks.first["label"])
    end
    assert_match(/expanded task data exceeds 1 MiB/, error.message)
  end

  private

  def task(label, command = ["ruby"], **options)
    {"label" => label, "command" => command, **options}
  end

  def loader(environment = {})
    Canopus::Task::Configuration.new(root: @root, environment: environment)
  end

  def write_tasks(source)
    File.binwrite(File.join(@root, ".canopus", "tasks.jsonc"), source)
  end
end
