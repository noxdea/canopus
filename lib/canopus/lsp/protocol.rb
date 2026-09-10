# frozen_string_literal: true

module Canopus
  module LSP
    module Protocol
      module_function
      def uri(path)
        absolute = File.expand_path(path).tr("\\", "/")
        absolute = "/#{absolute}" if absolute.match?(/\A[A-Za-z]:/)
        "file://" + URI::RFC2396_PARSER.escape(absolute, /[^a-zA-Z0-9\-._~\/:]/)
      end
      def path(uri)
        parsed = URI.parse(uri)
        raise Error, "expected local file URI" unless parsed.scheme == "file" && [nil, "", "localhost"].include?(parsed.host) && parsed.query.nil? && parsed.fragment.nil? && parsed.path&.start_with?("/")
        path = URI::RFC2396_PARSER.unescape(parsed.path)
        raise Error, "invalid file URI path" if path.include?("\0") || !path.valid_encoding?
        RUBY_PLATFORM.match?(/mswin|mingw/) ? path.sub(%r{\A/([A-Za-z]:/)}, '\\1') : path
      rescue URI::InvalidURIError => error
        raise Error, error.message
      end
      def position(rope, offset)
        point = rope.utf16_point_at(offset)
        {line: point.row, character: point.column}
      end
      def offset(rope, position)
        raise Error, "invalid LSP position" unless position.is_a?(Hash) && uint?(position["line"]) && uint?(position["character"])
        row, column = position.fetch("line"), position.fetch("character")
        start = rope.line_start(row)
        finish = start + rope.line(row).bytesize
        units = rope.utf16_offset_at(finish) - rope.utf16_offset_at(start)
        rope.offset_at_utf16(rope.utf16_offset_at(start) + [column, units].min)
      end
      def range(rope, range)
        {start: position(rope, range.begin), end: position(rope, range.end + (range.exclude_end? ? 0 : 1))}
      end
      def semantic_delta(data, edits)
        raise Error, "invalid semantic token delta" unless data.is_a?(Array) && edits.is_a?(Array)
        output = data.dup
        last = 0
        edits.each do |edit|
          raise Error, "invalid semantic token delta" unless edit.is_a?(Hash) && uint?(edit["start"]) && uint?(edit["deleteCount"]) && edit.fetch("data", []).is_a?(Array)
        end
        sorted = edits.sort_by { |edit| edit.fetch("start") }
        sorted.each do |edit|
          start, count = edit.fetch("start"), edit.fetch("deleteCount")
          raise Error, "invalid semantic token delta" unless start.is_a?(Integer) && count.is_a?(Integer) && start >= last && count >= 0 && start + count <= data.length
          last = start + count
        end
        sorted.reverse_each { |edit| output[edit.fetch("start"), edit.fetch("deleteCount")] = edit.fetch("data", []) }
        semantic_tokens(output)
        output
      end
      def uint?(value) = value.is_a?(Integer) && value.between?(0, 0x7fffffff)
      def diagnostics(values)
        valid = values.is_a?(Array) && values.all? do |value|
          next false unless value.is_a?(Hash) && value["message"].is_a?(String) && value["range"].is_a?(Hash)
          range = value["range"]
          points = %w[start end].map { |key| range[key] }
          points.all? { |point| point.is_a?(Hash) && uint?(point["line"]) && uint?(point["character"]) } &&
            ([points[0]["line"], points[0]["character"]] <=> [points[1]["line"], points[1]["character"]]) <= 0 &&
            (!value.key?("severity") || (value["severity"].is_a?(Integer) && value["severity"].between?(1, 4)))
        end
        raise Error, "invalid LSP diagnostics" unless valid
        values
      end
      def semantic_tokens(data, legend: nil)
        raise Error, "invalid semantic token tuple count" unless data.is_a?(Array) && data.length % 5 == 0
        if legend
          raise Error, "invalid semantic token legend" unless legend.is_a?(Hash) && %w[tokenTypes tokenModifiers].all? { |key| legend[key].is_a?(Array) && legend[key].all? { |name| name.is_a?(String) } }
        end
        row, column = 0, 0
        data.each_slice(5).map do |delta_row, delta_column, length, type, modifiers|
          raise Error, "invalid semantic token value" unless [delta_row, delta_column, length, type, modifiers].all? { |v| uint?(v) } && length.positive?
          raise Error, "semantic token exceeds legend" if legend && (type >= legend["tokenTypes"].length || modifiers.bit_length > legend["tokenModifiers"].length)
          row += delta_row
          column = delta_row.zero? ? column + delta_column : delta_column
          raise Error, "semantic token position overflow" unless uint?(row) && uint?(column + length)
          {line: row, character: column, length: length, type: type, modifiers: modifiers}
        end
      end
    end
  end
end
