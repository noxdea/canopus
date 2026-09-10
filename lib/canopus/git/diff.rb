# frozen_string_literal: true

module Canopus
  module Git
    module Diff
      Edit = Struct.new(:kind, :old_line, :new_line, :text, keyword_init: true)
      Hunk = Struct.new(:old_start, :old_count, :new_start, :new_count, :edits, keyword_init: true) do
        def old_text = edits.reject { |edit| edit.kind == :insert }.map(&:text).join
        def new_text = edits.reject { |edit| edit.kind == :delete }.map(&:text).join
      end
      module_function

      # Myers shortest edit script, with matching prefixes/suffixes removed first.
      def edits(before, after)
        left = before.is_a?(String) ? before.lines : before
        right = after.is_a?(String) ? after.lines : after
        prefix = 0
        prefix += 1 while prefix < left.length && prefix < right.length && left[prefix] == right[prefix]
        suffix = 0
        suffix += 1 while suffix < left.length - prefix && suffix < right.length - prefix && left[-suffix - 1] == right[-suffix - 1]
        a = left.slice(prefix, left.length - prefix - suffix)
        b = right.slice(prefix, right.length - prefix - suffix)
        middle = script(a, b)
        pairs = left.first(prefix).map { |line| [:equal, line] } + middle + (suffix.zero? ? [] : left.last(suffix).map { |line| [:equal, line] })
        old_line = new_line = 1
        pairs.map do |kind, text|
          edit = Edit.new(kind: kind, old_line: old_line, new_line: new_line, text: text)
          old_line += 1 unless kind == :insert
          new_line += 1 unless kind == :delete
          edit
        end
      end

      def hunks(before, after, context: 3)
        raise ArgumentError, "context must be nonnegative" unless context.is_a?(Integer) && context >= 0
        changes = edits(before, after)
        ranges = []
        changes.each_with_index do |edit, index|
          next if edit.kind == :equal
          first = [0, index - context].max
          last = [changes.length - 1, index + context].min
          if ranges.last && first <= ranges.last[1] + 1
            ranges.last[1] = last
          else
            ranges << [first, last]
          end
        end
        ranges.map do |first, last|
          items = changes[first..last]
          old_count = items.count { |edit| edit.kind != :insert }
          new_count = items.count { |edit| edit.kind != :delete }
          Hunk.new(old_start: items.first.old_line - (old_count.zero? ? 1 : 0), old_count: old_count,
            new_start: items.first.new_line - (new_count.zero? ? 1 : 0), new_count: new_count, edits: items)
        end
      end

      def revert(text, hunk)
        lines = text.lines
        start = hunk.new_count.zero? ? hunk.new_start : hunk.new_start - 1
        raise ArgumentError, "hunk no longer applies" unless lines.slice(start, hunk.new_count)&.join == hunk.new_text
        lines[start, hunk.new_count] = hunk.old_text.lines
        lines.join
      end

      def unified(before, after, old_name: "a/file", new_name: "b/file", context: 3)
        output = +"--- #{old_name}\n+++ #{new_name}\n"
        hunks(before, after, context: context).each do |hunk|
          output << "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@\n"
          hunk.edits.each do |edit|
            output << {equal: " ", delete: "-", insert: "+"}.fetch(edit.kind) << edit.text
            output << "\n\\ No newline at end of file\n" unless edit.text.end_with?("\n")
          end
        end
        output
      end

      def script(left, right)
        return right.map { |line| [:insert, line] } if left.empty?
        return left.map { |line| [:delete, line] } if right.empty?
        # Entirely replaced files have no diagonals to search: avoid O(n*m).
        return left.map { |line| [:delete, line] } + right.map { |line| [:insert, line] } unless left.intersect?(right)
        # The linear-space bisect avoids quadratic trace storage on large edits.
        x, y = bisect(left, right)
        if !x || (x.zero? && y.zero?) || (x == left.length && y == right.length)
          return left.map { |line| [:delete, line] } + right.map { |line| [:insert, line] }
        end
        # Reuse prefix/suffix trimming in each half through a local edit script.
        [edits(left[0...x], right[0...y]), edits(left[x..], right[y..])].flatten.map { |edit| [edit.kind, edit.text] }
      end
      private_class_method :script

      def bisect(left, right)
        n, m = left.length, right.length
        limit = (n + m + 1) / 2
        forward = {1 => 0}
        reverse = {1 => 0}
        delta = n - m
        odd = delta.odd?
        (0..limit).each do |depth|
          (-depth..depth).step(2) do |k|
            x = k == -depth || (k != depth && forward.fetch(k - 1, -1) < forward.fetch(k + 1, -1)) ? forward.fetch(k + 1, 0) : forward.fetch(k - 1, 0) + 1
            y = x - k
            while x < n && y < m && x >= 0 && y >= 0 && left[x] == right[y]
              x += 1
              y += 1
            end
            forward[k] = x
            if odd && reverse.key?(delta - k) && x + reverse[delta - k] >= n
              return [x, y]
            end
          end
          (-depth..depth).step(2) do |k|
            x = k == -depth || (k != depth && reverse.fetch(k - 1, -1) < reverse.fetch(k + 1, -1)) ? reverse.fetch(k + 1, 0) : reverse.fetch(k - 1, 0) + 1
            y = x - k
            while x < n && y < m && x >= 0 && y >= 0 && left[n - x - 1] == right[m - y - 1]
              x += 1
              y += 1
            end
            reverse[k] = x
            if !odd && forward.key?(delta - k) && forward[delta - k] + x >= n
              middle_x = forward[delta - k]
              return [middle_x, middle_x - (delta - k)]
            end
          end
        end
        nil
      end
      private_class_method :bisect
    end
  end
end
