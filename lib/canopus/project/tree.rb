# frozen_string_literal: true

require "set"

module Canopus
  class Project::Tree
    Entry = Data.define(:path, :name, :depth, :directory, :expanded)
    attr_reader :expanded
    def initialize(files, expanded: Set.new)
      @expanded, @children = expanded, Hash.new { |hash, key| hash[key] = {} }
      files.each do |path|
        parent = ""
        pieces = path.split("/")
        pieces.each_with_index do |piece, index|
          current = parent.empty? ? piece : "#{parent}/#{piece}"
          @children[parent][piece] = [current, index < pieces.length - 1 || path.end_with?("/")]
          parent = current
        end
      end
      @children.transform_values! { |children| children.sort_by { |name, (_, directory)| [directory ? 0 : 1, name.downcase, name] } }
    end
    def toggle(path)
      @expanded.include?(path) ? @expanded.delete(path) : @expanded.add(path)
      @visible = nil
    end
    def reveal(path)
      pieces = path.split("/")[0...-1]
      pieces.length.times { |index| @expanded.add(pieces.first(index + 1).join("/")) }
      @visible = nil
    end
    def visible
      @visible ||= begin
        output, stack = [], [["", 0]]
        until stack.empty?
          path, depth = stack.pop
          @children.fetch(path, []).reverse_each do |name, (child, directory)|
            stack << [Entry.new(child, name, depth, directory, @expanded.include?(child)), nil]
          end if path.is_a?(String)
          if path.is_a?(Entry)
            output << path
            stack << [path.path, path.depth + 1] if path.directory && path.expanded
          end
        end
        output.freeze
      end
    end
  end
end
