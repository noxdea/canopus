# frozen_string_literal: true
require_relative "test_helper"
require "open3"
require "rbconfig"
require "canopus/cli"
require "stringio"

class LauncherTest < Minitest::Test
  def test_launcher_enables_required_rubygems
    output, error, status = Open3.capture3({"CANOPUS_YJIT_REEXEC" => nil, "RUBYOPT" => nil}, RbConfig.ruby,
      "--disable-gems", File.expand_path("../exe/canopus", __dir__), "--version")
    assert status.success?, error
    assert_equal "#{Canopus::VERSION}\n", output
  end

  def test_cli_reuses_an_opt_in_glyph_cache
    Dir.mktmpdir("canopus-glyph-cache-") do |root|
      cache = File.join(root, "glyphs")
      args = ["--project", root, "--headless", File.join(root, "frame.png"), "--size", "160x100", "--glyph-cache", cache]
      error = StringIO.new
      assert_equal 0, Canopus::CLI.main(args, output: StringIO.new, error: error), error.string
      files = Dir[File.join(cache, "*.atlas")]
      refute_empty files
      stamps = files.to_h { |path| [path, File.stat(path).mtime] }
      assert_equal 0, Canopus::CLI.main(args, output: StringIO.new, error: error), error.string
      assert_equal stamps, files.to_h { |path| [path, File.stat(path).mtime] }
    end
  end

  def test_native_windows_boot_does_not_attempt_yjit_reexec
    %w[x64-mingw-ucrt x64-mswin64].each do |platform|
      code = <<~RUBY
        Object.send(:remove_const, :RUBY_PLATFORM)
        Object.const_set(:RUBY_PLATFORM, #{platform.inspect})
        RubyVM.send(:remove_const, :YJIT) if defined?(RubyVM::YJIT)
        Kernel.prepend(Module.new { def exec(*) = raise("unexpected YJIT re-exec") })
        load #{File.expand_path("../exe/canopus", __dir__).inspect}
      RUBY
      output, error, status = Open3.capture3({"CANOPUS_YJIT_REEXEC" => "1"}, RbConfig.ruby, "-e", code, "--", "--version")
      assert status.success?, error
      assert_equal Canopus::VERSION, output.strip
    end
  end
end
