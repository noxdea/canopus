# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class EncodingTest < Minitest::Test
  def test_menkar_detection_is_retained_and_roundtrips
    Dir.mktmpdir("canopus-encoding-") do |dir|
      path = File.join(dir, "utf16.txt")
      source = "日本\r\nline\r\n"
      bytes = "\xFF\xFE".b + source.encode(Encoding::UTF_16LE).b
      File.binwrite(path, bytes)
      buffer = Canopus::Buffer.open(path)

      assert_equal Encoding::UTF_16LE, buffer.encoding
      assert_equal :crlf, buffer.newline
      assert_equal source, buffer.text
      assert buffer.roundtrip?
      buffer.save
      assert_equal bytes, File.binread(path)
    ensure
      buffer&.close
    end
  end

  def test_open_uses_explicit_encoding_instead_of_utf8_detection
    Dir.mktmpdir("canopus-encoding-") do |dir|
      path = File.join(dir, "utf8.txt")
      File.binwrite(path, "日本".encode(Encoding::UTF_8))
      buffer = Canopus::Buffer.open(path, encoding: Encoding::Windows_31J)

      assert_equal Encoding::Windows_31J, buffer.encoding
      assert_equal "譌･譛ｬ", buffer.text
    ensure
      buffer&.close
    end
  end

  def test_short_bomless_japanese_legacy_text_prefers_windows_31j
    raw = "first\n日本\nlast\n".encode(Encoding::Windows_31J).b
    text, encoding, bom = Canopus::Buffer.decode_bytes(raw)

    assert_equal "日本", text.lines[1].chomp
    assert_equal Encoding::Windows_31J, encoding
    assert_empty bom
  end

  def test_buffer_new_retains_explicit_encoding_when_saved
    Dir.mktmpdir("canopus-encoding-") do |dir|
      path = File.join(dir, "new.txt")
      buffer = Canopus::Buffer.new("日本", path: path, encoding: Encoding::Windows_31J)
      buffer.save

      assert_equal Encoding::Windows_31J, buffer.encoding
      assert_equal "日本".encode(Encoding::Windows_31J).b, File.binread(path)
    ensure
      buffer&.close
    end
  end

  def test_unrepresentable_save_is_reported_as_canopus_error
    Dir.mktmpdir("canopus-encoding-") do |dir|
      buffer = Canopus::Buffer.new("🙂")

      assert_raises(Canopus::Error) { buffer.save(File.join(dir, "legacy.txt"), encoding: Encoding::Windows_31J) }
    ensure
      buffer&.close
    end
  end

  def test_mixed_newlines_can_be_converted
    buffer = Canopus::Buffer.new("one\ntwo\r\nthree\r")
    assert buffer.mixed_line_endings?
    assert_equal :mixed, buffer.newline

    assert buffer.convert_line_endings(to: :lf)
    assert_equal "one\ntwo\nthree\n", buffer.text
    assert_equal :lf, buffer.newline
    refute buffer.mixed_line_endings?
  end

  def test_large_files_use_denebola_lazy_rope
    Dir.mktmpdir("canopus-large-") do |dir|
      path = File.join(dir, "large.txt")
      File.binwrite(path, "line\n" * 100)
      buffer = Canopus::Buffer.open(path, large_file_threshold: 1)

      assert_instance_of Denebola::LazyRope, buffer.rope
      assert_predicate buffer, :read_only
      assert_equal :lf, buffer.newline
      assert_equal "line", buffer.line(0)
    ensure
      buffer&.close
    end
  end

  def test_workspace_encoding_actions_can_save_as_another_encoding
    Dir.mktmpdir("canopus-workspace-encoding-") do |dir|
      path = File.join(dir, "sample.txt")
      File.write(path, "日本\n")
      workspace = Canopus::Workspace.new(root: dir)
      editor = workspace.open(path)
      workspace.show_encoding_actions(editor.buffer)
      index = workspace.palette[:matches].index("Save as UTF-16LE")
      refute_nil index
      workspace.palette[:index] = index
      workspace.palette_accept

      assert_equal "\xFF\xFE".b, File.binread(path, 2)
      assert_equal Encoding::UTF_16LE, editor.buffer.encoding
    ensure
      workspace&.close
    end
  end

  def test_workspace_confirms_mixed_line_ending_conversion
    Dir.mktmpdir("canopus-workspace-encoding-") do |dir|
      path = File.join(dir, "mixed.txt")
      source = "one\ntwo\r\nthree\r"
      File.binwrite(path, source)
      workspace = Canopus::Workspace.new(root: dir)
      editor = workspace.open(path)

      workspace.convert_line_endings(:lf)
      assert_equal :confirm_line_ending_conversion, workspace.palette[:kind]
      assert_equal source, editor.buffer.text

      workspace.palette_accept
      assert_equal source, editor.buffer.text
      workspace.convert_line_endings(:lf)
      workspace.palette[:index] = 0
      workspace.palette_accept
      assert_equal "one\ntwo\nthree\n", editor.buffer.text
    ensure
      workspace&.close
    end
  end

  def test_encoding_save_warning_does_not_report_success
    Dir.mktmpdir("canopus-workspace-encoding-") do |dir|
      path = File.join(dir, "sample.txt")
      source = "🙂\n"
      File.write(path, source)
      workspace = Canopus::Workspace.new(root: dir)
      editor = workspace.open(path)
      workspace.show_encoding_actions(editor.buffer)
      index = workspace.palette[:matches].index("Save as Windows-31J")
      refute_nil index
      workspace.palette[:index] = index
      workspace.palette_accept

      assert_equal :confirm_encoding_save, workspace.palette[:kind]
      refute_equal "Saved as Windows-31J", workspace.message
      assert_equal source, File.read(path)
    ensure
      workspace&.close
    end
  end
end
