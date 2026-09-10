# frozen_string_literal: true

require "ripper"
require_relative "test_helper"

class FileLayoutTest < Minitest::Test
  LAYOUT_EXCEPTIONS = %w[data_compat.rb match_data_compat.rb regexp_compat.rb].freeze
  VAGUE_SUFFIX = /(?:Services|Actions|Methods|Mixin|Concern|Module)\z/
  MIXED_ACRONYM = /(?:\A|[a-z\d])(?:Api|Cli|Lsp|Odb|Pty|Ui|Vt)(?:\z|[A-Z])/
  ACRONYMS = {"api" => "API", "cli" => "CLI", "lsp" => "LSP", "pty" => "PTY", "vt" => "VT"}.freeze

  def test_production_constants_have_focused_names_and_matching_files
    Dir[File.expand_path("../lib/**/*.rb", __dir__)].sort.each do |path|
      tree = Ripper.sexp(File.read(path))
      definitions = definition_paths(tree)
      classes = definitions.fetch(:class)
      assert_operator classes.length, :<=, 1, "#{path} defines #{classes.join(', ')}"
      names = (classes + definitions.fetch(:value) + definitions.fetch(:module)).reject { |name| name == "Canopus" }
      names.each do |name|
        leaf = name.split("::").last
        refute_match VAGUE_SUFFIX, leaf, path
        refute_match MIXED_ACRONYM, leaf, path
      end
      next if names.empty? || LAYOUT_EXCEPTIONS.include?(File.basename(path))
      basename = File.basename(path, ".rb")
      assert names.any? { |name| underscore(name.split("::").last) == basename }, "#{path} defines #{names.join(', ')}"
      relative = path.delete_prefix(File.expand_path("../lib", __dir__) + File::SEPARATOR).delete_suffix(".rb")
      expected = relative.split("/").map { |part| constantize(part) }.join("::")
      assert_includes names, expected, "#{path} should define #{expected}"
    end
  end

  private

  def definition_paths(node, namespace = [], definitions = {class: [], module: [], value: []})
    return definitions unless node.is_a?(Array)
    if [:class, :module].include?(node.first)
      path = namespace + constant_name(node[1]).split("::")
      definitions.fetch(node.first) << path.join("::")
      body = node[node.first == :class ? 3 : 2]
      return definition_paths(body, path, definitions)
    end
    if node.first == :assign && node[1]&.first == :var_field && node[1][1]&.first == :@const && (node[2].flatten & %w[Data Struct]).any?
      definitions.fetch(:value) << [*namespace, node[1][1][1]].join("::")
    end
    node.each { |child| definition_paths(child, namespace, definitions) if child.is_a?(Array) }
    definitions
  end

  def constant_name(node)
    return node[1] if node.first == :@const
    node.filter_map { |child| constant_name(child) if child.is_a?(Array) }.join("::")
  end

  def underscore(name)
    name.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\\1_\\2').gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
  end

  def constantize(name)
    ACRONYMS.fetch(name) { name.split("_").map(&:capitalize).join }
  end
end
