# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class DebugConfigurationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("canopus-debug-")
    FileUtils.mkdir_p(File.join(@root, ".canopus"))
  end

  def teardown
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def test_loads_jsonc_expands_context_and_resolves_adapter
    source = File.join(@root, "lib", "example.rb")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, "puts :ok\n")
    write_launch(<<~JSONC)
      {
        // Comments and trailing commas are accepted.
        "configurations": [{
          "name": "Run current file",
          "type": "ruby",
          "request": "launch",
          "program": "${file}",
          "args": ["--line=${lineNumber}", "${selectedText}", "${env:TOKEN}"],
          "cwd": "${workspaceFolder}",
        }],
      }
    JSONC
    token = +"secret"
    settings = Canopus::Settings.new("debug_adapters" => {"ruby" => {
      "command" => ["rdbg", "--port", "${env:PORT}"], "transport" => "tcp"
    }})
    loader = Canopus::Debug::Configuration.new(root: @root, settings: settings,
      environment: {"TOKEN" => token, "PORT" => "1234"})
    token.replace("changed")

    entry = loader.configurations.first
    resolved = loader.resolve(entry, file: source, line_number: 7, selected_text: "日本\ntext")
    adapter = loader.adapter("ruby")

    assert_equal File.realpath(source), resolved["program"]
    assert_equal ["--line=7", "日本\ntext", "secret"], resolved["args"]
    assert_equal loader.root, resolved["cwd"]
    assert_equal({"command" => ["rdbg", "--port", "1234"], "transport" => "tcp"}, adapter)
    assert entry.frozen?
    assert entry["args"].frozen?
    assert resolved.frozen?
    assert resolved["args"].all?(&:frozen?)
    assert adapter["command"].frozen?
  end

  def test_resolves_a_configuration_by_name
    write_launch(JSON.generate("configurations" => [configuration("Named")]))
    loader = build_loader
    assert_equal "Named", loader.resolve("Named")["name"]
    assert_raises(Canopus::Error) { loader.resolve("Missing") }
    assert_raises(Canopus::Error) { loader.resolve(configuration("Named")) }
  end

  def test_missing_unknown_and_malformed_variables_are_errors
    cases = {
      "${file}" => /file is unavailable/,
      "${lineNumber}" => /lineNumber is unavailable/,
      "${selectedText}" => /selectedText is unavailable/,
      "${env:MISSING}" => /environment variable MISSING is unavailable/,
      "${unknown}" => /unknown debug variable/,
      "${file" => /malformed debug variable/
    }
    cases.each do |value, message|
      write_launch(JSON.generate("configurations" => [configuration("Case", "args" => [value])]))
      error = assert_raises(Canopus::Error) { build_loader.resolve("Case") }
      assert_match message, error.message
    end
  end

  def test_replacement_text_is_not_reinterpreted_as_a_variable
    write_launch(JSON.generate("configurations" => [configuration("Literal", "args" => [
      "${selectedText}", "${env:LITERAL}"
    ])]))
    loader = Canopus::Debug::Configuration.new(root: @root, settings: Canopus::Settings.new,
      environment: {"LITERAL" => "${file}"})
    resolved = loader.resolve("Literal", selected_text: "${env:MISSING}")
    assert_equal ["${env:MISSING}", "${file}"], resolved["args"]
  end

  def test_context_replacements_must_be_utf8_or_ascii_only
    write_launch(JSON.generate("configurations" => [configuration("Encoding", "args" => ["${selectedText}"])]))
    loader = build_loader
    assert_raises(Canopus::Error) { loader.resolve("Encoding", selected_text: "\xff".b) }
    utf16 = "valid text".encode(Encoding::UTF_16LE)
    assert utf16.valid_encoding?
    assert_raises(Canopus::Error) { loader.resolve("Encoding", selected_text: utf16) }
  end

  def test_expansion_has_a_shared_budget
    large = "x" * (600 * 1024)
    write_launch(JSON.generate("configurations" => [configuration("Large", "args" => [
      "${env:LARGE}", "${env:LARGE}"
    ])]))
    loader = Canopus::Debug::Configuration.new(root: @root, settings: Canopus::Settings.new,
      environment: {"LARGE" => large})
    error = assert_raises(Canopus::Error) { loader.resolve("Large") }
    assert_match(/expanded debug data exceeds 1 MiB/, error.message)

    settings = Canopus::Settings.new("debug_adapters" => {"ruby" => {
      "command" => ["${env:LARGE}", "${env:LARGE}"], "transport" => "stdio"
    }})
    loader = Canopus::Debug::Configuration.new(root: @root, settings: settings,
      environment: {"LARGE" => large})
    assert_raises(Canopus::Error) { loader.adapter("ruby") }

    repeated = "${env:CHUNK}" * 65
    write_launch(JSON.generate("configurations" => [configuration("Repeated", "args" => [repeated])]))
    loader = Canopus::Debug::Configuration.new(root: @root, settings: Canopus::Settings.new,
      environment: {"CHUNK" => "x" * 16_384})
    assert_raises(Canopus::Error) { loader.resolve("Repeated") }
  end

  def test_environment_snapshot_is_bounded_before_copying
    write_launch(JSON.generate("configurations" => [configuration("Run")]))
    large = "x" * (600 * 1024)
    error = assert_raises(Canopus::Error) do
      Canopus::Debug::Configuration.new(root: @root, settings: Canopus::Settings.new,
        environment: {"FIRST" => large, "SECOND" => large})
    end
    assert_match(/environment exceeds 1 MiB/, error.message)
    assert_raises(Canopus::Error) do
      Canopus::Debug::Configuration.new(root: @root, settings: Canopus::Settings.new,
        environment: {"INVALID" => "\xff".b})
    end
  end

  def test_rejects_unsafe_paths_and_invalid_context
    write_launch(JSON.generate("configurations" => [configuration("Escape",
      "program" => "${workspaceFolder}/../outside.rb", "cwd" => "${workspaceFolder}")]))
    error = assert_raises(Canopus::Error) { build_loader.resolve("Escape") }
    assert_match(/outside the workspace/, error.message)

    write_launch(JSON.generate("configurations" => [configuration("File", "program" => "${file}")]))
    loader = build_loader
    assert_raises(Canopus::Error) { loader.resolve("File", file: File.join(@root, "..", "outside.rb")) }

    write_launch(JSON.generate("configurations" => [configuration("Line", "args" => ["${lineNumber}"])]))
    assert_raises(Canopus::Error) { build_loader.resolve("Line", line_number: 0) }
  end

  def test_rejects_a_symlinked_launch_file_outside_the_workspace
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    outside = Dir.mktmpdir("canopus-debug-outside-")
    begin
      path = File.join(@root, ".canopus", "launch.jsonc")
      File.write(File.join(outside, "launch.jsonc"), JSON.generate("configurations" => []))
      File.symlink(File.join(outside, "launch.jsonc"), path)
      assert_raises(Canopus::Error) { build_loader }
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  def test_rejects_a_program_reached_through_an_outside_symlink
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    outside = Dir.mktmpdir("canopus-debug-program-")
    begin
      File.symlink(outside, File.join(@root, "linked"))
      write_launch(JSON.generate("configurations" => [configuration("Linked",
        "program" => "${workspaceFolder}/linked/program.rb")]))
      assert_raises(Canopus::Error) { build_loader.resolve("Linked") }
    ensure
      FileUtils.remove_entry(outside)
    end
  end

  def test_nonexistent_paths_are_rebuilt_from_the_canonical_ancestor
    skip "symlink creation is not generally available on Windows" if Gem.win_platform?
    FileUtils.mkdir_p(File.join(@root, "real"))
    linked = File.join(@root, "linked")
    begin
      File.symlink(File.join(@root, "real"), linked)
    rescue NotImplementedError, Errno::EPERM
      skip "symlink creation is unavailable"
    end
    write_launch(JSON.generate("configurations" => [configuration("Missing", "program" => "${file}")]))
    loader = build_loader
    resolved = loader.resolve("Missing", file: File.join(linked, "new.rb"))
    assert_equal File.join(loader.root, "real", "new.rb"), resolved["program"]
    refute_includes resolved["program"], "linked"

    ordinary = loader.resolve("Missing", file: File.join(@root, "new", "file.rb"))
    assert_equal File.join(loader.root, "new", "file.rb"), ordinary["program"]
  end

  def test_nonexistent_paths_resolve_the_macos_var_alias
    skip "macOS-specific path alias" unless /darwin/ =~ RUBY_PLATFORM
    write_launch(JSON.generate("configurations" => [configuration("Alias", "program" => "${file}")]))
    loader = build_loader
    skip "temporary directory does not use the /var alias" unless @root.start_with?("/var/") && loader.root.start_with?("/private/var/")
    path = File.join(@root, "missing", "file.rb")
    assert_equal File.join(loader.root, "missing", "file.rb"), loader.resolve("Alias", file: path)["program"]
  end

  def test_validates_launch_shape_bounds_and_encoding
    invalid = [
      [],
      {"configurations" => {}},
      {"configurations" => [configuration("")]},
      {"configurations" => [configuration("Bad", "type" => "ruby shell")]},
      {"configurations" => [configuration("Bad", "request" => "run")]},
      {"configurations" => [configuration("Bad", "args" => [1])]},
      {"configurations" => [configuration("Bad", "env" => {"NAME" => 1})]},
      {"configurations" => [configuration("Same"), configuration("Same")]},
      {"configurations" => Array.new(129) { |index| configuration("Run #{index}") }}
    ]
    invalid.each do |document|
      write_launch(JSON.generate(document))
      assert_raises(Canopus::Error) { build_loader }
    end

    File.binwrite(File.join(@root, ".canopus", "launch.jsonc"), "{\"configurations\":[]}" + (" " * 1_048_577))
    assert_raises(Canopus::Error) { build_loader }
    File.binwrite(File.join(@root, ".canopus", "launch.jsonc"), "\xff".b)
    assert_raises(Canopus::Error) { build_loader }
  end

  def test_returns_a_frozen_rake_test_proposal_for_ruby_projects
    File.write(File.join(@root, "Rakefile"), "task :test\n")
    loader = build_loader
    expected = {"name" => "Run tests", "type" => "ruby", "request" => "launch",
      "program" => "${workspaceFolder}/bin/rake", "args" => ["test"], "cwd" => "${workspaceFolder}"}
    assert_equal [expected], loader.configurations
    assert loader.configurations.frozen?
    assert loader.configurations.first.frozen?
    assert_equal File.join(loader.root, "bin", "rake"), loader.resolve("Run tests")["program"]

    FileUtils.rm_f(File.join(@root, "Rakefile"))
    assert_empty build_loader.configurations
  end

  def test_debug_adapter_settings_are_strict_bounded_and_snapshotted
    adapters = {"ruby" => {"command" => ["rdbg", "--open"], "transport" => "tcp"}}
    settings = Canopus::Settings.new("debug_adapters" => adapters)
    adapters["ruby"]["command"] << "changed"
    assert_equal ["rdbg", "--open"], settings["debug_adapters"].dig("ruby", "command")
    assert settings["debug_adapters"].dig("ruby", "command").frozen?
    assert_equal({}, Canopus::Settings.new["debug_adapters"])
    schema = Canopus::Settings.schema.dig("properties", "debug_adapters")
    assert_equal 64, schema["maxProperties"]
    assert_equal({"type" => "string", "minLength" => 1, "maxLength" => 128,
      "pattern" => "^[A-Za-z0-9_.-]+$"}, schema["propertyNames"])
    command_schema = Canopus::Settings.schema.dig("$defs", "debug_adapter", "properties", "command", "items")
    assert_equal 4096, command_schema["maxLength"]
    assert Regexp.new(command_schema["pattern"]).match?("rdbg --open")
    refute Regexp.new(command_schema["pattern"]).match?("bad\tcommand")

    invalid = [
      [],
      {ruby: {"command" => ["rdbg"], "transport" => "stdio"}},
      {"ruby" => {command: ["rdbg"], "transport" => "stdio"}},
      {"ruby" => {"command" => [], "transport" => "stdio"}},
      {"ruby" => {"command" => ["bad\ncommand"], "transport" => "stdio"}},
      {"ruby" => {"command" => ["bad\tcommand"], "transport" => "stdio"}},
      {"ruby" => {"command" => ["rdbg"], "transport" => "socket"}},
      {"ruby" => {"command" => ["rdbg"], "transport" => "stdio", "extra" => true}},
      (0..64).to_h { |index| ["adapter#{index}", {"command" => ["run"], "transport" => "stdio"}] }
    ]
    invalid.each { |value| assert_raises(Canopus::Error) { Canopus::Settings.new("debug_adapters" => value) } }

    oversized = 64.times.to_h do |index|
      ["adapter#{index}", {"command" => Array.new(32) { "x" * 600 }, "transport" => "stdio"}]
    end
    error = assert_raises(Canopus::Error) { Canopus::Settings.new("debug_adapters" => oversized) }
    assert_match(/1 MiB/, error.message)
  end

  def test_debug_adapters_are_global_and_layers_reload_cleanly
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("languages" => {"ruby" => {"debug_adapters" => {
        "ruby" => {"command" => ["rdbg"], "transport" => "stdio"}
      }}})
    end
    assert_raises(Canopus::Error) do
      Canopus::Settings.new("languages" => {"ruby" => {debug_adapters: {
        "ruby" => {"command" => ["rdbg"], "transport" => "stdio"}
      }}})
    end

    user_path = File.join(@root, "user.jsonc")
    project_path = File.join(@root, "project.jsonc")
    File.write(user_path, JSON.generate("debug_adapters" => {
      "ruby" => {"command" => ["rdbg"], "transport" => "stdio"}
    }))
    File.write(project_path, JSON.generate("debug_adapters" => {
      "ruby" => {"command" => ["bundle", "exec", "rdbg"], "transport" => "tcp"}
    }))
    settings = Canopus::Settings.new(user_path, project_path)
    assert_equal ["bundle", "exec", "rdbg"], settings["debug_adapters"].dig("ruby", "command")
    assert settings["debug_adapters"].dig("ruby", "command").frozen?
    File.write(project_path, JSON.generate("debug_adapters" => {
      "ruby" => {"command" => ["rdbg", "--open"], "transport" => "stdio"}
    }))
    assert_equal ["rdbg", "--open"], settings.reload["debug_adapters"].dig("ruby", "command")
  end

  def test_missing_adapter_is_an_error
    write_launch(JSON.generate("configurations" => [configuration("Run")]))
    assert_raises(Canopus::Error) { build_loader.adapter("ruby") }
  end

  private

  def configuration(name, overrides = {})
    {"name" => name, "type" => "ruby", "request" => "launch"}.merge(overrides)
  end

  def write_launch(source)
    File.binwrite(File.join(@root, ".canopus", "launch.jsonc"), source)
  end

  def build_loader
    Canopus::Debug::Configuration.new(root: @root, settings: Canopus::Settings.new, environment: {})
  end
end
