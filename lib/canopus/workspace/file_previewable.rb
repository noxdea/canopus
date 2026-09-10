# frozen_string_literal: true

module Canopus
  module Workspace::FilePreviewable
    # A preview never creates a tab, loads a complete file, or changes selections.
    def file_preview(path)
      absolute = canonical_path(path)
      buffer = @buffers[absolute]
      stamp = buffer ? buffer.version : [File.mtime(absolute), File.size(absolute)]
      key = [absolute, stamp]
      @file_previews ||= {}
      return @file_previews[key] if @file_previews.key?(key)
      source = if buffer
        ending = [16_384, buffer.rope.bytesize].min
        begin
          buffer.rope.byteslice(0, ending).to_s
        rescue RangeError
          ending -= 1
          retry
        end
      else
        File.binread(absolute, 16_384).force_encoding(Encoding::UTF_8).scrub
      end
      rows = source.include?("\0") ? ["Binary / UTF-16 preview unavailable"] : source.lines.first(40).map { |line| line.chomp[0, 300] }
      @file_previews.shift if @file_previews.length >= 16
      @file_previews[key] = rows.freeze
    rescue SystemCallError, Error => error
      ["Preview unavailable: #{error.message}"]
    end
  end
end
