# frozen_string_literal: true

require "uri"

module Canopus
  module Terminal
    class VT
      DEC_GRAPHICS = {"`" => "◆", "a" => "▒", "f" => "°", "g" => "±", "j" => "┘", "k" => "┐",
        "l" => "┌", "m" => "└", "n" => "┼", "o" => "⎺", "p" => "⎻", "q" => "─", "r" => "⎼", "s" => "⎽",
        "t" => "├", "u" => "┤", "v" => "┴", "w" => "┬", "x" => "│", "y" => "≤", "z" => "≥", "{" => "π", "|" => "≠", "}" => "£", "~" => "·"}.freeze
      attr_reader :grid, :title, :cwd, :modes, :replies, :bell_count

      def initialize(grid = Grid.new, &reply)
        @grid = grid
        @reply = reply
        @replies = []
        @input = +"".b
        @state = :ground
        @sequence = +"".b
        @modes = {7 => true, 25 => true}
        @charsets = [:ascii, :ascii]
        @charset = 0
        @bell_count = 0
      end

      # The parser retains incomplete UTF-8 and control sequences between reads.
      def feed(bytes)
        @input << bytes.b
        index = 0
        while index < @input.bytesize
          byte = @input.getbyte(index)
          if @state == :ground && byte >= 0xa0
            length = if byte.between?(0xc2, 0xdf) then 2
            elsif byte.between?(0xe0, 0xef) then 3
            elsif byte.between?(0xf0, 0xf4) then 4
            else 1 end
            break if index + length > @input.bytesize
            char = @input.byteslice(index, length).force_encoding(Encoding::UTF_8)
            unless char.valid_encoding?
              char = "\ufffd"
              length = 1
            end
            print(char)
            index += length
            next
          end
          consume(byte)
          index += 1
        end
        @input = @input.byteslice(index..) || +"".b
        self
      end

      def paste(text)
        modes[2004] ? "\e[200~#{text.gsub("\e[201~", "")}\e[201~" : text
      end

      def mouse(button:, column:, row:, action: :press, shift: false, alt: false, control: false)
        tracking = [1000, 1002, 1003].find { |mode| modes[mode] }
        return "" unless tracking
        return "" if action == :move && (tracking == 1000 || (tracking == 1002 && button.nil?))
        code = case button
        when :left, 0 then 0
        when :middle, 1 then 1
        when :right, 2 then 2
        when :wheel_up then 64
        when :wheel_down then 65
        else 3 end
        code |= 32 if action == :move
        code |= 4 if shift
        code |= 8 if alt
        code |= 16 if control
        column = [column + 1, 1].max
        row = [row + 1, 1].max
        if modes[1006]
          "\e[<#{code};#{column};#{row}#{action == :release ? 'm' : 'M'}"
        else
          code = (code & ~3) | 3 if action == :release
          return "" if column > 223 || row > 223
          "\e[M".b + [code + 32, column + 32, row + 32].pack("C3")
        end
      end

      def key(name, shift: false, alt: false, control: false)
        name = name.to_s
        modifier = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0)
        arrows = {"up" => "A", "down" => "B", "right" => "C", "left" => "D", "home" => "H", "end" => "F"}
        if arrows.key?(name)
          return modifier > 1 ? "\e[1;#{modifier}#{arrows[name]}" : "\e#{modes[1] ? 'O' : '['}#{arrows[name]}"
        end
        function = {"insert" => 2, "delete" => 3, "page_up" => 5, "page_down" => 6,
          "f5" => 15, "f6" => 17, "f7" => 18, "f8" => 19, "f9" => 20, "f10" => 21, "f11" => 23, "f12" => 24}
        return "\e[#{function[name]}#{modifier > 1 ? ";#{modifier}" : ''}~" if function.key?(name)
        if /\Af[1-4]\z/.match?(name)
          final = ("P".ord + name[1].to_i - 1).chr
          return modifier > 1 ? "\e[1;#{modifier}#{final}" : "\eO#{final}"
        end
        return "\e[Z" if name == "tab" && shift
        text = {"enter" => "\r", "backspace" => "\x7f", "tab" => "\t", "escape" => "\e"}.fetch(name, name)
        text = (text.upcase.ord & 0x1f).chr if control && text.length == 1 && ("@".."_").cover?(text.upcase)
        text = "\0" if control && text == " "
        alt ? "\e#{text}" : text
      end

      private

      def consume(byte)
        if [:osc, :dcs, :string].include?(@state)
          return consume_string(byte)
        end
        if byte == 0x1b
          @state = :escape
          @sequence.clear
          return
        elsif [0x18, 0x1a].include?(byte)
          @state = :ground
          return
        elsif byte < 0x20 || byte == 0x7f
          control(byte)
          return
        end
        case @state
        when :ground
          case byte
          when 0x9b then start_sequence(:csi)
          when 0x9d then start_sequence(:osc)
          when 0x90 then start_sequence(:dcs)
          when 0x84 then grid.linefeed
          when 0x85 then grid.carriage_return; grid.linefeed
          when 0x8d then grid.reverse_index
          else print(byte.chr) if byte < 0x80
          end
        when :escape
          case byte.chr
          when "[" then start_sequence(:csi)
          when "]" then start_sequence(:osc)
          when "P" then start_sequence(:dcs)
          when "_", "^", "X" then start_sequence(:string)
          when "(" then @charset_target = 0; @state = :charset
          when ")" then @charset_target = 1; @state = :charset
          when "#", "%" then @state = :escape_intermediate; @sequence << byte
          else
            escape(byte.chr)
            @state = :ground
          end
        when :escape_intermediate
          if @sequence == "#" && byte == "8".ord
            grid.cells.each { |row| row.each { |cell| cell.text = "E"; cell.width = 1 } }
          end
          @state = :ground
        when :charset
          @charsets[@charset_target] = byte == "0".ord ? :graphics : :ascii
          @state = :ground
        when :csi
          if byte.between?(0x40, 0x7e)
            csi(byte.chr, @sequence)
            @state = :ground
          elsif @sequence.bytesize < 1024 && byte.between?(0x20, 0x3f)
            @sequence << byte
          else
            @state = :csi_ignore
          end
        when :csi_ignore
          @state = :ground if byte.between?(0x40, 0x7e)
        end
      end

      def start_sequence(state)
        @state = state
        @sequence = +"".b
        @string_escape = @string_overflow = false
        @string_utf8_remaining = 0
      end

      def consume_string(byte)
        if @string_utf8_remaining.positive? && byte.between?(0x80, 0xbf)
          @string_utf8_remaining -= 1
          append_string(byte)
          return
        end
        @string_utf8_remaining = if byte.between?(0xc2, 0xdf) then 1
        elsif byte.between?(0xe0, 0xef) then 2
        elsif byte.between?(0xf0, 0xf4) then 3
        else 0 end
        if byte == 0x9c || (@string_escape && byte == 0x5c) || (byte == 7 && @state == :osc)
          if !@string_overflow
            osc(@sequence) if @state == :osc
            dcs(@sequence) if @state == :dcs
          end
          @state = :ground
          @string_escape = false
        elsif [0x18, 0x1a].include?(byte)
          @state = :ground
        elsif byte == 0x1b
          @string_escape = true
        else
          @sequence << 0x1b if @string_escape && !@string_overflow
          @string_escape = false
          append_string(byte)
        end
      end

      def append_string(byte)
        @sequence.bytesize < 16_384 ? @sequence << byte : @string_overflow = true
      end

      def control(byte)
        case byte
        when 7 then @bell_count += 1
        when 8 then grid.backspace
        when 9 then grid.tab
        when 10, 11, 12 then grid.linefeed; grid.carriage_return if modes[20]
        when 13 then grid.carriage_return
        when 14 then @charset = 1
        when 15 then @charset = 0
        end
      end

      def escape(char)
        case char
        when "7" then grid.save_cursor
        when "8" then grid.restore_cursor
        when "D" then grid.linefeed
        when "E" then grid.carriage_return; grid.linefeed
        when "M" then grid.reverse_index
        when "H" then grid.tab_set
        when "=" then @modes[:keypad] = true
        when ">" then @modes[:keypad] = false
        when "c" then grid.reset; @modes = {7 => true, 25 => true}; @charsets = [:ascii, :ascii]; @charset = 0
        end
      end

      def print(char)
        char = DEC_GRAPHICS.fetch(char, char) if @charsets[@charset] == :graphics
        grid.put(char)
        @last_printed = char
      end

      def csi(final, sequence)
        prefix = sequence[/\A[?<=>]/]
        parameters = sequence.sub(/\A[?<=>]/, "").sub(/[\x20-\x2f]+\z/, "")
        values = parameters.split(";", -1).map { |value| value.empty? ? 0 : value.to_i.clamp(0, 1_000_000) }
        values = [0] if values.empty?
        amount = values.first.zero? ? 1 : values.first
        case final
        when "A" then grid.move(y: grid.cursor_y - amount)
        when "B", "e" then grid.move(y: grid.cursor_y + amount)
        when "C", "a" then grid.move(x: grid.cursor_x + amount)
        when "D" then grid.move(x: grid.cursor_x - amount)
        when "E" then grid.move(x: 0, y: grid.cursor_y + amount)
        when "F" then grid.move(x: 0, y: grid.cursor_y - amount)
        when "G", "`" then grid.move(x: amount - 1)
        when "H", "f" then grid.position(amount, values[1].to_i.zero? ? 1 : values[1])
        when "d" then grid.position(amount, grid.cursor_x + 1)
        when "I" then grid.tab([amount, grid.columns].min)
        when "Z" then grid.tab([amount, grid.columns].min, backward: true)
        when "J" then grid.erase_display(values.first)
        when "K" then grid.erase_line(values.first)
        when "L" then grid.insert_lines(amount)
        when "M" then grid.delete_lines(amount)
        when "P" then grid.delete_characters(amount)
        when "@" then grid.insert_characters(amount)
        when "X" then grid.erase_characters(amount)
        when "S" then grid.scroll_up(amount)
        when "T" then grid.scroll_down(amount) unless values.length > 1
        when "r" then grid.margins(amount, values[1].to_i.zero? ? grid.rows : values[1]) unless prefix
        when "s" then grid.save_cursor
        when "u" then grid.restore_cursor
        when "g" then grid.tab_clear(all: values.first == 3)
        when "m" then sgr(parameters) unless prefix
        when "h", "l" then values.each { |mode| set_mode(mode, final == "h", prefix == "?") }
        when "b" then [amount, grid.columns * grid.rows].min.times { grid.put(@last_printed) } if @last_printed
        when "n"
          emit("\e[0n") if values.first == 5
          emit("\e[#{prefix == '?' ? '?' : ''}#{grid.cursor_y + 1};#{grid.cursor_x + 1}R") if values.first == 6
        when "c"
          emit(prefix == ">" ? "\e[>0;1;0c" : "\e[?1;2c")
        when "t"
          emit("\e[8;#{grid.rows};#{grid.columns}t") if values.first == 18
          emit("\e]l#{title}\e\\") if values.first == 21
        when "p"
          if sequence.end_with?("!")
            grid.attributes = {}.freeze
            grid.foreground = grid.background = nil
            grid.insert_mode = grid.origin_mode = false
            grid.autowrap = grid.cursor_visible = true
            grid.margins
          elsif sequence.end_with?("$")
            state = modes.key?(values.first) ? modes[values.first] ? 1 : 2 : 0
            emit("\e[?#{values.first};#{state}$y")
          end
        end
      end

      def set_mode(mode, enabled, private_mode)
        @modes[mode] = enabled
        if private_mode
          case mode
          when 6 then grid.origin_mode = enabled; grid.position(1, 1)
          when 7 then grid.autowrap = enabled
          when 25 then grid.cursor_visible = enabled
          when 47, 1047 then grid.alternate(enabled, save: false)
          when 1048 then enabled ? grid.save_cursor : grid.restore_cursor
          when 1049 then grid.alternate(enabled)
          when 1000, 1002, 1003
            [1000, 1002, 1003].each { |other| @modes[other] = false unless other == mode } if enabled
          end
        elsif mode == 4
          grid.insert_mode = enabled
        end
      end

      def sgr(parameters)
        # Colon subparameters are retained for underline styles and ISO RGB.
        groups = parameters.empty? ? ["0"] : parameters.split(";", -1)
        attributes = grid.attributes.dup
        index = 0
        while index < groups.length
          parts = groups[index].split(":", -1)
          value = parts.first.to_i
          case value
          when 0 then attributes.clear; grid.foreground = grid.background = nil
          when 1 then attributes[:bold] = true
          when 2 then attributes[:dim] = true
          when 3 then attributes[:italic] = true
          when 4 then attributes[:underline] = parts[1] ? parts[1].to_i : 1
          when 5, 6 then attributes[:blink] = true
          when 7 then attributes[:inverse] = true
          when 8 then attributes[:hidden] = true
          when 9 then attributes[:strikethrough] = true
          when 21 then attributes[:underline] = 2
          when 22 then attributes.delete(:bold); attributes.delete(:dim)
          when 23 then attributes.delete(:italic)
          when 24 then attributes.delete(:underline)
          when 25 then attributes.delete(:blink)
          when 27 then attributes.delete(:inverse)
          when 28 then attributes.delete(:hidden)
          when 29 then attributes.delete(:strikethrough)
          when 30..37 then grid.foreground = value - 30
          when 40..47 then grid.background = value - 40
          when 90..97 then grid.foreground = value - 90 + 8
          when 100..107 then grid.background = value - 100 + 8
          when 39 then grid.foreground = nil
          when 49 then grid.background = nil
          when 38, 48, 58
            color = nil
            if parts.length > 1
              kind = parts[1].to_i
              color = kind == 5 ? parts[2]&.to_i : kind == 2 && parts.length >= 5 ? parts.last(3).map(&:to_i) : nil
            else
              kind = groups[index + 1]&.to_i
              count = kind == 5 ? 1 : kind == 2 ? 3 : 0
              if count.positive? && index + 1 + count < groups.length
                color = count == 1 ? groups[index + 2].to_i : groups[index + 2, count].map(&:to_i)
                index += count + 1
              end
            end
            color = color.map { |part| part.clamp(0, 255) }.freeze if color.is_a?(Array)
            color = color.clamp(0, 255) if color.is_a?(Integer)
            if color
              value == 38 ? grid.foreground = color : value == 48 ? grid.background = color : attributes[:underline_color] = color
            end
          when 59 then attributes.delete(:underline_color)
          end
          index += 1
        end
        grid.attributes = attributes.freeze
      end

      def osc(sequence)
        command, payload = sequence.force_encoding(Encoding::UTF_8).scrub.split(";", 2)
        return unless payload
        case command
        when "0", "2" then @title = payload
        when "7"
          uri = URI.parse(payload)
          @cwd = URI::RFC2396_PARSER.unescape(uri.path) if uri.scheme == "file" && uri.path&.start_with?("/")
        when "8"
          _, url = payload.split(";", 2)
          grid.hyperlink = url.nil? || url.empty? ? nil : url.freeze
        end
      rescue URI::InvalidURIError
        nil
      end

      def dcs(sequence)
        return unless sequence.start_with?("$q")
        request = sequence.delete_prefix("$q")
        answer = {"m" => "0m", "r" => "#{grid.scroll_top + 1};#{grid.scroll_bottom + 1}r"}[request]
        emit("\eP#{answer ? 1 : 0}$r#{answer || request}\e\\")
      end

      def emit(bytes)
        @reply ? @reply.call(bytes) : @replies << bytes
      end
    end
  end
end
