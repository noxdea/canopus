# frozen_string_literal: true

module Canopus
  # Bounded, edit-aware row textures shared by every pane showing a buffer.
  class Minimap
    GENERATION_LIMIT = 24
    ENTRY_LIMIT = 2_048
    VARIANT_LIMIT = 4
    LINE_BYTES = 4_096

    attr_reader :generated

    def initialize
      @variants, @subscriptions, @search = {}, {}, {}
      @next_key = @frame = 0
      @generated, @pending = 0, false
    end

    def begin_frame(frame, text_system:, font_size:, font_family:, scale_factor:)
      identity = [text_system&.object_id, text_system&.respond_to?(:font) ? text_system.font.object_id : nil,
        font_size, font_family, scale_factor]
      rebuild if @identity && @identity != identity
      @identity, @text_system, @font_size, @scale_factor = identity, text_system, font_size, scale_factor
      return if @frame == frame

      @frame, @generated, @pending = frame, 0, false
    end

    def texture(buffer, row, width:)
      return unless @text_system && row.is_a?(Integer) && row.between?(0, buffer.line_count - 1)
      variant = variant(width)
      pair = [buffer, row]
      if (entry = variant[:entries].delete(pair))
        variant[:entries][pair] = entry
        return variant[:cache].texture(entry[:key], outlines: [])
      end
      unless @generated < GENERATION_LIMIT
        @pending = true
        return
      end

      attach(buffer)
      source = line_source(buffer.rope, row)
      layout = @text_system.layout_line(source, size: @font_size)
      outlines = []
      layout.glyphs.each do |glyph|
        break if glyph.x * 0.1 >= width
        begin
          factor = @font_size.to_f / glyph.font.units_per_em
          outlines << glyph.font.outline(glyph.id).transform([factor, 0, 0, -factor, glyph.x, layout.ascent])
        rescue StandardError
          nil
        end
      end
      key = @next_key += 1
      texture = variant[:cache].texture(key, outlines: outlines)
      variant[:entries][pair] = {key: key, offset: buffer.rope.line_start(row)}
      trim(variant)
      @generated += 1
      texture
    rescue StandardError
      nil
    end

    def pending? = @pending
    def cache_size = @variants.values.sum { |variant| variant[:entries].length }
    def cached_rows(buffer) = @variants.values.flat_map { |variant| variant[:entries].keys.filter_map { |source, row| row if source.equal?(buffer) } }.uniq.sort

    def record_search(buffer, version, ranges)
      attach(buffer)
      rows = ranges.first(10_000).filter_map do |range|
        buffer.rope.point_at(range.begin).row if range.is_a?(Range) && range.begin.is_a?(Integer)
      rescue RangeError
        nil
      end
      @search[buffer] = {version: version, rows: rows.sort.uniq.freeze}.freeze
    end

    def search_rows(buffer, version)
      entry = @search[buffer]
      entry && entry[:version] == version ? entry[:rows] : []
    end

    def release(buffer)
      @variants.each_value { |variant| remove_buffer(variant, buffer) }
      @subscriptions.delete(buffer)&.detach
      @search.delete(buffer)
      nil
    end

    def close
      @subscriptions.each_value(&:detach)
      @subscriptions.clear
      rebuild
      @search.clear
      nil
    end

    private

    def variant(width)
      width = Integer(width)
      key = [width, @scale_factor]
      cached = @variants.delete(key)
      return @variants[key] = cached if cached

      while @variants.length >= VARIANT_LIMIT
        _old_key, old = @variants.shift
        old[:cache].close
      end
      scale = Float(@scale_factor)
      texture_width, texture_height, max_bytes = (width * scale).ceil, (2 * scale).ceil, 8 << 20
      limit = [ENTRY_LIMIT, max_bytes / (texture_width * texture_height)].min.clamp(1, ENTRY_LIMIT)
      cache = Zaniah::TextSystem::LowResolutionTextCache.new(width: texture_width,
        height: texture_height, scale: 0.1 * scale, capacity: limit, max_bytes: max_bytes)
      @variants[key] = {cache: cache, entries: {}, limit: limit}
    end

    def rebuild
      @variants.each_value { |variant| variant[:cache].close }
      @variants.clear
    end

    def attach(buffer)
      @subscriptions[buffer] ||= buffer.on_edit { |patch| edited(buffer, patch) }
    end

    def trim(variant)
      while variant[:entries].length > variant[:limit]
        _pair, entry = variant[:entries].shift
        variant[:cache].invalidate(entry[:key])
      end
    end

    def remove_buffer(variant, buffer)
      variant[:entries].delete_if do |(source, _row), entry|
        next false unless source.equal?(buffer)

        variant[:cache].invalidate(entry[:key])
        true
      end
    end

    def edited(buffer, patch)
      @search.delete(buffer)
      if patch.is_a?(Patch::Reload)
        @variants.each_value { |variant| remove_buffer(variant, buffer) }
      else
        parts = patch.is_a?(Patch::Composite) ? patch.patches : [patch]
        parts.each do |part|
          if part.is_a?(Patch::Reload)
            @variants.each_value { |variant| remove_buffer(variant, buffer) }
          else
            apply_patch(buffer, part)
          end
        end
      end
    end

    def apply_patch(buffer, patch)
      affected = patch.edits.map do |edit|
        patch.before.point_at(edit.old_range.begin).row..patch.before.point_at(edit.old_range.end).row
      end
      @variants.each_value do |variant|
        mapped = {}
        variant[:entries].each do |(source, row), entry|
          unless source.equal?(buffer)
            mapped[[source, row]] = entry
            next
          end
          offset = patch.map_offset(entry[:offset], bias: :right)
          new_row = patch.after.point_at(offset).row
          changed = affected.any? { |range| range.cover?(row) }
          aligned = patch.after.line_start(new_row) == offset
          same_line = !changed || line_source(patch.before, row) == line_source(patch.after, new_row)
          unless aligned && same_line && !mapped.key?([buffer, new_row])
            variant[:cache].invalidate(entry[:key])
            next
          end
          mapped[[buffer, new_row]] = {key: entry[:key], offset: offset}
        end
        variant[:entries] = mapped
      end
    end

    def line_source(rope, row)
      return rope.line_window(row, max_bytes: LINE_BYTES).first if rope.respond_to?(:line_window)

      first = rope.line_start(row)
      last = row + 1 < rope.line_count ? rope.line_start(row + 1) : rope.bytesize
      ending = [first + LINE_BYTES, last].min
      begin
        rope.point_at(ending)
      rescue RangeError
        ending -= 1
        retry
      end
      rope.byteslice(first, ending - first).to_s.sub(/(?:\r\n|[\r\n\u2028\u2029])\z/, "")
    end
  end
end
