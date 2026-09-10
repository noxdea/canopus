# frozen_string_literal: true

module Canopus
  module Vim::TextObjectSelectable
    private

    def text_object(key, inner:, count: 1)
      source
      position = character_index(cursor_position)
      case key
      when "w", "W"
        return if @characters.empty?
        big = key == "W"
        first = last = [position, @characters.length - 1].min
        initial = word_class(@characters[first], big)
        first -= 1 while first.positive? && word_class(@characters[first - 1], big) == initial && !@characters[first - 1].include?("\n")
        last += 1 while last < @characters.length && word_class(@characters[last], big) == initial && !@characters[last].include?("\n")
        (count - 1).times do
          last += 1 while !inner && last < @characters.length && word_class(@characters[last], big) == :space
          klass = word_class(@characters[last], big)
          last += 1 while last < @characters.length && word_class(@characters[last], big) == klass
        end
        unless inner
          if initial == :space
            klass = word_class(@characters[last], big)
            last += 1 while last < @characters.length && word_class(@characters[last], big) == klass
          else
            trailing = last
            last += 1 while last < @characters.length && @characters[last].match?(/[ \t]/)
            first -= 1 while last == trailing && first.positive? && @characters[first - 1].match?(/[ \t]/)
          end
        end
        @offsets[first]...@offsets[last]
      when "p" then paragraph_object(inner, count)
      when "s" then sentence_object(inner, count)
      when "t" then tag_object(position, inner, count)
      when '"', "'", "`"
        row = row_at(cursor_position)
        start_index, end_index = character_index(line_start(row)), character_index(line_end(row))
        quotes = (start_index...end_index).select { |index| @characters[index] == key && !escaped_character?(index) }
        pairs = quotes.each_slice(2).select { |pair| pair.length == 2 }
        pair = pairs.find { |first, last| first <= position && position <= last } || pairs.find { |first, _| first > position }
        return unless pair
        first, last = pair
        if inner
          first += 1
        else
          trailing = last + 1
          last += 1 while last + 1 < end_index && @characters[last + 1].match?(/[ \t]/)
          first -= 1 while last + 1 == trailing && first > start_index && @characters[first - 1].match?(/[ \t]/)
        end
        @offsets[first]...@offsets[inner ? pair.last : last + 1]
      else
        left, right = {"(" => ["(", ")"], ")" => ["(", ")"], "b" => ["(", ")"],
          "[" => ["[", "]"], "]" => ["[", "]"], "{" => ["{", "}"], "}" => ["{", "}"],
          "B" => ["{", "}"], "<" => ["<", ">"], ">" => ["<", ">"]}[key]
        return unless left
        stack, enclosing = [], []
        @characters.each_with_index do |character, index|
          stack << index if character == left
          if character == right && !stack.empty?
            first = stack.pop
            enclosing << [first, index] if first <= position && index >= position
          end
        end
        first, last = enclosing[count - 1]
        return unless first
        first += 1 if inner
        last += 1 unless inner
        @offsets[first]...@offsets[last]
      end
    end

    def escaped_character?(index)
      slashes = 0
      while index.positive? && @characters[index - 1] == "\\"
        slashes += 1
        index -= 1
      end
      slashes.odd?
    end

    def paragraph_object(inner, count)
      first = last = row_at(cursor_position)
      blank = @editor.buffer.line(first).strip.empty?
      first -= 1 while first.positive? && @editor.buffer.line(first - 1).strip.empty? == blank
      last += 1 while last < last_row && @editor.buffer.line(last + 1).strip.empty? == blank
      (count - 1).times do
        last += 1 while last < last_row && @editor.buffer.line(last + 1).strip.empty?
        last += 1 while last < last_row && !@editor.buffer.line(last + 1).strip.empty?
      end
      unless inner
        ending = last
        last += 1 while last < last_row && @editor.buffer.line(last + 1).strip.empty? != blank
        first -= 1 while last == ending && first.positive? && @editor.buffer.line(first - 1).strip.empty?
      end
      line_start(first)...(last + 1 < @editor.buffer.line_count ? line_start(last + 1) : @editor.buffer.rope.bytesize)
    end

    def sentence_object(inner, count)
      positions, first = [], 0
      source.to_enum(:scan, /[.!?]["')\]]*(?=\s|\z)|\n[ \t]*\n/).each do
        match = Regexp.last_match
        ending = source[0...match.end(0)].bytesize
        positions << (first...ending)
        first = ending
      end
      positions << (first...source.bytesize) if first < source.bytesize
      index = positions.index { |range| range.end > cursor_position }
      return unless index
      first = positions[index].begin
      last = positions[[index + count - 1, positions.length - 1].min].end
      first += source.byteslice(first...last)[/\A\s*/].bytesize
      if inner
        last -= source.byteslice(first...last)[/\s*\z/].bytesize
      else
        last += source.byteslice(last..)[/\A\s*/].bytesize
      end
      first...last
    end

    def tag_object(position, inner, count)
      stack, enclosing = [], []
      source.to_enum(:scan, /<\/?([\w:-]+)\b(?:"[^"]*"|'[^']*'|[^'">])*>/).each do
        match = Regexp.last_match
        first, last = source[0...match.begin(0)].bytesize, source[0...match.end(0)].bytesize
        if match[0].start_with?("</")
          opening = stack.rindex { |item| item[0] == match[1] }
          next unless opening
          _tag, left, content = stack[opening]
          stack.slice!(opening..)
          enclosing << [left, content, first, last] if left <= @offsets[position] && last > @offsets[position]
        elsif !match[0].end_with?("/>")
          stack << [match[1], first, last]
        end
      end
      entry = enclosing[count - 1]
      entry && (inner ? entry[1]...entry[2] : entry[0]...entry[3])
    end
  end
end
