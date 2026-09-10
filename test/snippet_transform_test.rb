# frozen_string_literal: true

require_relative "test_helper"

class SnippetTransformTest < Minitest::Test
  def transform(pattern, replacement, flags = "", value = "")
    Canopus::Snippet.new("${VALUE/#{pattern}/#{replacement}/#{flags}}", variables: {"VALUE" => value}).text
  end

  def test_official_examples_and_capture_substitution
    assert_equal "example", transform('(.*)\..+$', '$1', "", "example.rb")
    assert_equal "EXAMPLE.RB", transform('(.*)', '${1:/upcase}', "", "example.rb")
    assert_equal "example_rb", transform('[\.-]', '_', "g", "example.rb")
    assert_equal "foo", transform('([a-z]+)(\d+)', '$1', "", "foo42")
    assert_equal "42/foo/foo42", transform('([a-z]+)(\d+)', '${2}/${1}/$0'.gsub('/', '\/'), "", "foo42")
    assert_equal "日本", transform('(日本)', '$1', "u", "日本")
    assert_equal "a/b", transform('a\/b', '$0', "", "a/b")
  end

  def test_case_formats
    {"upcase" => "HELLO WORLD", "downcase" => "hello world", "capitalize" => "Hello world", "camelcase" => "helloWorld",
      "pascalcase" => "HelloWorld", "snakecase" => "hello_world", "kebabcase" => "hello-world"}.each do |format, expected|
      assert_equal expected, transform('(.*)', "${1:/#{format}}", "", "hello world"), format
    end
    assert_equal "http-server-url", transform('(.*)', '${1:/kebabcase}', "", "HTTPServerURL")
    assert_equal "日本語Value", transform('(.*)', '${1:/camelcase}', "", "日本語 value")
  end

  def test_conditionals_empty_captures_and_no_match_fallback
    {'${1:+yes}' => ["yes", ""], '${1:?yes:no}' => ["yes", "no"], '${1:-no}' => ["a", "no"], '${1:no}' => ["a", "no"]}.each do |format, expected|
      assert_equal expected[0], transform('(a)?', format, "", "a"), format
      assert_equal expected[1], transform('(a)?', format, "", ""), format
    end
    assert_equal "default", transform('(missing)', '${1:-default}', "", "original")
    assert_equal "original", transform('(missing)', '${1:+yes}', "", "original")
    assert_equal "日本", transform('(missing)', '${1:日本}', "", "original")
    assert_equal "A", transform('(a)', '${1:?${1:/upcase}:none}', "", "a")
    assert_equal "no:way", transform('(a)?', '${1:?yes:no\:way}', "", "")
  end

  def test_global_empty_matches_case_insensitivity_dotall_and_anchors
    assert_equal "xbx", transform('a', 'x', "gi", "AbA")
    assert_equal "-x-x-x", transform('(?=.)', '-', "g", "xxx")
    assert_equal "-日-本-", transform('', '-', "gu", "日本")
    assert_equal "x\nb", transform('^.', 'x', "", "a\nb")
    assert_equal "x\nx", transform('^.', 'x', "gm", "a\nb")
    assert_equal "x\ny", transform('.', 'x', "", "a\ny")
    assert_equal "x", transform('.*', 'x', "s", "a\nb")
    assert_equal "x\r\nx", transform('.', 'x', "g", "a\r\nb")
    assert_equal "a\nx", transform('.$', 'x', "", "a\nb")
    assert_equal "a\n", transform('a$', 'x', "", "a\n")
    assert_equal "x\rx", transform('^.', 'x', "gm", "a\rb")
    assert_equal "x\u2028x", transform('^.', 'x', "gm", "a\u2028b")
    assert_equal "a-x", transform('\b日', '-x', "", "a日")
    assert_equal "a_x", transform('\s', '_', "", "a\ufeffx")
    assert_equal "x", transform('.', 'x', "u", "😀")
    assert_raises(Canopus::Error) { transform('.', 'x', "", "😀") }
    assert_raises(Canopus::Error) { transform('\B', 'x', "u", "a😀b") }
  end

  def test_invalid_flags_patterns_and_formats_are_explicit_errors
    %w[y d v x gg ii].each { |flags| assert_raises(Canopus::Error) { transform('x', 'y', flags, 'x') } }
    ['[', '\\A', '(?>a)', '(?i:a)', 'a++', '\\p{Letter}', '(?<named>a)', '(a)\\1', '(a(b)?)+'].each do |pattern|
      assert_raises(Canopus::Error, pattern) { transform(pattern, 'x', '', 'a') }
    end
    %w[ß ſ K İ].each { |value| assert_raises(Canopus::Error) { transform('s', 'x', 'iu', value) } }
    assert_raises(Canopus::Error) { transform('(?:' * 33 + 'a' + ')' * 33, 'x', '', 'a') }
    assert_raises(Canopus::Error) { transform('a', '$' + '9' * 10_000, '', 'a') }
    ['${1:/unknown}', '${1:?missing}', '${x}', '${1'].each do |format|
      assert_raises(Canopus::Error, format) { transform('(a)', format, '', 'a') }
    end
  end

  def test_regex_timeout_and_output_limit
    # A bounded engine still needs a deadline for expensive counted repetitions.
    source = 'a' * 1_000_000 + '!'
    error = assert_raises(Canopus::Error) { transform('a{10000}b', 'x', '', source) }
    assert_match(/timed out/, error.message)
    assert_raises(Canopus::Error) { transform('(.*)', '$1$1', '', 'a' * (Canopus::Snippet::MAX_OUTPUT / 2 + 1)) }
  end
end
