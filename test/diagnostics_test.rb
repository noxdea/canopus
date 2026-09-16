# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DiagnosticsTest < Minitest::Test
  def diagnostic(message, severity: 1, line: 0)
    {"message" => message, "severity" => severity, "range" => {
      "start" => {"line" => line, "character" => 0},
      "end" => {"line" => line, "character" => 1}
    }}
  end

  def test_registry_replaces_each_source_and_uri_and_filters_entries
    Dir.mktmpdir("canopus-diagnostic-registry-") do |root|
      first = Sadr::Protocol.uri(File.join(root, "first.rb"))
      second = Sadr::Protocol.uri(File.join(root, "second.rb"))
      changed = []
      registry = Canopus::Diagnostics::Registry.new { |uri| changed << uri }
      original = diagnostic(+"broken", severity: 1)

      registry.publish(:lsp, first, [original])
      registry.publish(:task, first, [diagnostic("lint", severity: 2)])
      registry.publish(:test, second, [diagnostic("failed", severity: 1)])
      original["message"].replace("mutated")

      assert_equal %i[lsp task], registry.for_uri(first).map(&:source)
      assert_equal ["broken"], registry.all(source: :lsp).map { |entry| entry.diagnostic["message"] }
      assert_equal %i[lsp test], registry.all(severity: :error).map(&:source)
      assert_equal({error: 2, warning: 1, information: 0, hint: 0}, registry.counts)
      assert_equal [first, first, second], changed

      registry.publish(:task, second, [diagnostic("quiet")], notify: false)
      assert_equal [first, first, second], changed

      registry.publish(:lsp, first, [])
      assert_equal [:task], registry.for_uri(first).map(&:source)
    end
  end

  def test_registry_rejects_untrusted_sources_uris_messages_ranges_and_sizes
    registry = Canopus::Diagnostics::Registry.new
    uri = Sadr::Protocol.uri("/tmp/source.rb")
    invalid_utf8 = "x".b.force_encoding(Encoding::UTF_8)
    invalid_utf8.setbyte(0, 0xff)

    assert_raises(ArgumentError) { registry.publish(:unknown, uri, []) }
    assert_raises(ArgumentError) { registry.publish(:lsp, "https://example.test/source.rb", []) }
    assert_raises(ArgumentError) { registry.publish(:lsp, uri, [diagnostic(invalid_utf8)]) }
    assert_raises(ArgumentError) do
      registry.publish(:lsp, uri, [diagnostic("reversed").tap do |value|
        value["range"]["start"]["line"] = 2
      end])
    end
    assert_raises(ArgumentError) { registry.publish(:lsp, uri, [diagnostic("x", severity: 5)]) }
    assert_raises(ArgumentError) { registry.publish(:lsp, uri, [diagnostic("x").merge("source" => "x" * 4_097)]) }
    assert_raises(ArgumentError) { registry.publish(:lsp, uri, [diagnostic("x").merge(extra: true)]) }
    assert_raises(ArgumentError) do
      registry.publish(:lsp, uri, Array.new(Canopus::Diagnostics::PUBLICATION_LIMIT + 1) { diagnostic("x") })
    end
    cyclic = {}
    cyclic["self"] = cyclic
    assert_raises(ArgumentError) do
      registry.publish(:task, uri, [diagnostic("cyclic").merge("data" => cyclic)])
    end
  end
end
