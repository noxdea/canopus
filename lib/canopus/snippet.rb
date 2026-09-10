# frozen_string_literal: true

require "strscan"

module Canopus
  # LSP/TextMate snippets. All exported offsets are UTF-8 byte offsets.
  class Snippet
    MAX_SOURCE = 1 << 20
    MAX_OUTPUT = 4 << 20
    MAX_DEPTH = 32
    MAX_NODES = 10_000
    VARIABLES = %w[TM_SELECTED_TEXT TM_CURRENT_LINE TM_CURRENT_WORD TM_LINE_INDEX TM_LINE_NUMBER
      TM_FILENAME TM_FILENAME_BASE TM_DIRECTORY TM_FILEPATH RELATIVE_FILEPATH CLIPBOARD
      WORKSPACE_NAME WORKSPACE_FOLDER CURSOR_INDEX CURSOR_NUMBER CURRENT_YEAR CURRENT_YEAR_SHORT
      CURRENT_MONTH CURRENT_MONTH_NAME CURRENT_MONTH_NAME_SHORT CURRENT_DATE CURRENT_DAY_NAME
      CURRENT_DAY_NAME_SHORT CURRENT_HOUR CURRENT_MINUTE CURRENT_SECOND CURRENT_MILLISECOND
      CURRENT_SECONDS_UNIX CURRENT_MILLISECONDS_UNIX CURRENT_TIMEZONE_OFFSET CURRENT_TIMEZONE_NAME
      RANDOM RANDOM_HEX UUID BLOCK_COMMENT_START BLOCK_COMMENT_END LINE_COMMENT].freeze
    Occurrence = Data.define(:index, :range, :transform, :parents)
    Node = Struct.new(:index, :children, :choices, :transform)
    private_constant :Node
    attr_reader :text, :tabstops, :choices, :transforms, :occurrences

    def initialize(source, variables: {})
      raise Error, "snippet must be valid UTF-8" unless source.is_a?(String) && source.valid_encoding? && (source.encoding == Encoding::UTF_8 || (source.encoding.ascii_compatible? && source.ascii_only?))
      raise Error, "snippet exceeds #{MAX_SOURCE} bytes" if source.bytesize > MAX_SOURCE
      raise Error, "snippet variables must be a Hash" unless variables.is_a?(Hash)
      @variables = variables.to_h do |key, value|
        raise Error, "snippet variable values must be UTF-8 strings or nil" unless value.nil? || (value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || (value.encoding.ascii_compatible? && value.ascii_only?)))
        raise Error, "snippet variable exceeds output limit" if value && value.bytesize > MAX_OUTPUT
        [key.to_s, value&.encode(Encoding::UTF_8)]
      end
      @scanner, @node_count, @maximum_index = StringScanner.new(source), 0, 0
      nodes = parse
      nodes = resolve_variables(nodes)
      @defaults, @choices = {}, {}
      collect_defaults(nodes)
      @text, @tabstops, @transforms = +"", Hash.new { |h, k| h[k] = [] }, []
      @occurrences = []
      render(nodes)
      @text.freeze
      @tabstops = @tabstops.sort_by { |index, _| index.zero? ? Float::INFINITY : index }.to_h.transform_values { |ranges| ranges.freeze }.freeze
      @choices.freeze
      @transforms.freeze
      @occurrences.freeze
      # The parse tree and variable values are not retained by a live editor.
      @scanner = @variables = @defaults = nil
    end

    private

    def parse(ending = nil, depth = 0)
      raise Error, "snippet nesting exceeds #{MAX_DEPTH}" if depth > MAX_DEPTH
      nodes, literal = [], +""
      until @scanner.eos?
        character = @scanner.getch
        if character == ending
          nodes << literal unless literal.empty?
          return nodes
        elsif character == "\\" && @scanner.peek(1).match?(/[\\$}]/)
          literal << @scanner.getch
        elsif character == "$"
          braced = !!@scanner.scan(/\{/)
          identifier = @scanner.scan(/\d+|[A-Za-z_][A-Za-z_0-9]*/)
          if !identifier && !braced
            literal << "$"
            next
          end
          raise Error, "invalid snippet identifier" unless identifier
          nodes << literal unless literal.empty?
          literal = +""
          numbered = identifier.match?(/\A\d+\z/)
          raise Error, "snippet tabstop index is too long" if numbered && identifier.length > 7
          index = numbered ? Integer(identifier, 10) : identifier
          raise Error, "snippet tabstop index is too large" if index.is_a?(Integer) && index > 1_000_000
          @maximum_index = [@maximum_index, index].max if index.is_a?(Integer)
          node = Node.new(index)
          @node_count += 1
          raise Error, "too many snippet nodes" if @node_count > MAX_NODES
          if braced
            case @scanner.getch
            when "}" # Bare tabstop or variable.
            when ":" then node.children = parse("}", depth + 1)
            when "|"
              raise Error, "choices require a numbered tabstop" unless index.is_a?(Integer)
              node.choices = parse_choices
              node.children = [node.choices.first]
            when "/" then node.transform = Transform.parse(@scanner, depth + 1)
            else raise Error, "invalid or unclosed snippet placeholder"
            end
          end
          nodes << node
        else
          literal << character
        end
      end
      raise Error, "unclosed snippet placeholder" if ending
      nodes << literal unless literal.empty?
      nodes
    end

    def parse_choices
      choices, value = [], +""
      until @scanner.eos?
        character = @scanner.getch
        if character == "\\" && @scanner.peek(1).match?(/[\\,|]/)
          value << @scanner.getch
        elsif character == ","
          choices << value.freeze
          value = +""
        elsif character == "|" && @scanner.scan(/\}/)
          choices << value.freeze
          return choices.freeze
        else
          value << character
        end
        raise Error, "too many snippet choices" if choices.length >= MAX_NODES
      end
      raise Error, "unclosed snippet choice"
    end

    def resolve_variables(nodes)
      nodes.flat_map do |node|
        next node if node.is_a?(String)
        if node.index.is_a?(Integer)
          node.children = resolve_variables(node.children) if node.children
          [node]
        elsif node.transform
          [node.transform.apply(@variables[node.index] || "")]
        elsif @variables[node.index]
          [@variables[node.index]]
        elsif node.children
          resolve_variables(node.children)
        elsif @variables.key?(node.index) || VARIABLES.include?(node.index)
          [""]
        else
          @maximum_index += 1
          [Node.new(@maximum_index, [node.index])]
        end
      end
    end

    def collect_defaults(nodes)
      nodes.each do |node|
        next if node.is_a?(String)
        @defaults[node.index] ||= node.children if node.children && !node.children.empty?
        @choices[node.index] ||= node.choices if node.choices
        collect_defaults(node.children) if node.children
      end
    end

    def render(nodes, ancestors = [])
      nodes.each do |node|
        if node.is_a?(String)
          raise Error, "expanded snippet exceeds #{MAX_OUTPUT} bytes" if @text.bytesize + node.bytesize > MAX_OUTPUT
          @text << node
          next
        end
        raise Error, "cyclic snippet placeholder #{node.index}" if ancestors.include?(node.index)
        raise Error, "expanded snippet nesting exceeds #{MAX_DEPTH}" if ancestors.length >= MAX_DEPTH
        start = @text.bytesize
        # Transformed mirrors start with the placeholder value, and change on Tab.
        # Their nested fields are not independent editable tabstops.
        previous_tabstops, previous_transforms, previous_occurrences = @tabstops, @transforms, @occurrences if node.transform
        @tabstops, @transforms, @occurrences = Hash.new { |h, k| h[k] = [] }, [], [] if node.transform
        render(@defaults[node.index] || [], [*ancestors, node.index])
        @tabstops, @transforms, @occurrences = previous_tabstops, previous_transforms, previous_occurrences if node.transform
        range = (start...@text.bytesize).freeze
        occurrence = Occurrence.new(node.index, range, node.transform, ancestors.freeze)
        @occurrences << occurrence
        if node.transform
          @transforms << occurrence
        else
          @tabstops[node.index] << range
        end
        @rendered_nodes = (@rendered_nodes || 0) + 1
        raise Error, "too many expanded snippet nodes" if @rendered_nodes > MAX_NODES
      end
    end
  end
end

require_relative "snippet/transform"
