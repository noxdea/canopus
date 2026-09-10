# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/vim_cases"
require "json"

class VimDifferentialTest < Minitest::Test
  ORACLE = JSON.parse(File.read(File.join(__dir__, "fixtures/vim_oracle.json"))).freeze
  CASES = VimCases.all.freeze
  raise "regenerate the Vim oracle fixture" unless CASES.map { |item| item[:name] } == ORACLE.map { |item| item.fetch("name") }

  CASES.zip(ORACLE).each_with_index do |(item, expected), index|
    define_method("test_vim_#{index}_#{item.fetch(:name).gsub(/[^a-zA-Z0-9]/, '_')}") do
      editor = Canopus::Editor.new(Canopus::Buffer.new(item.fetch(:text)))
      editor.select(item.fetch(:start))
      vim = Canopus::Vim.new(editor)
      item.fetch(:keys).each { |key| vim.feed(key) }
      register = vim.registers['"'] || ["", false]
      type = register[1] == true ? "V" : (register[1] == :block ? "\x16#{register[2]}" : "v")
      assert_equal expected.fetch("text"), editor.buffer.text, item.fetch(:name)
      assert_equal expected.fetch("cursor"), vim.cursor_position, item.fetch(:name)
      assert_equal expected.fetch("register"), register[0], item.fetch(:name)
      assert_equal expected.fetch("type"), type, item.fetch(:name)
    ensure
      vim&.dispose
      editor&.dispose
    end
  end
end
