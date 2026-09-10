# frozen_string_literal: true

# Deliberately uses bounded Ruby Regexp, never eval or an external JS runtime.
# Supported syntax and JS portability boundaries are in docs/snippets.md.
class Canopus::Snippet::Transform
  TIMEOUT = 0.05
  SPACE = '\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff'
  CASES = %w[upcase downcase capitalize camelcase pascalcase snakecase kebabcase].freeze
  Format = Data.define(:index, :operation, :positive, :negative)
  private_constant :Format
  attr_reader :pattern, :flags

  def self.parse(scanner, depth)
    pattern = +""
    closed = false
    until scanner.eos?
      character = scanner.getch
      if character == "\\"
        following = scanner.getch
        raise Canopus::Error, "unclosed snippet transform" unless following
        pattern << (following == "/" ? "/" : "\\#{following}")
      elsif character == "/"
        closed = true
        break
      else
        pattern << character
      end
    end
    raise Canopus::Error, "unclosed snippet transform pattern" unless closed
    replacement = parse_format(scanner, ["/"], depth)
    raise Canopus::Error, "unclosed snippet transform replacement" unless scanner.getch == "/"
    flags = scanner.scan(/[A-Za-z]*/)
    raise Canopus::Error, "unclosed snippet transform" unless scanner.getch == "}"
    new(pattern, replacement, flags)
  end

  def self.parse_format(scanner, endings, depth, budget = [0])
    raise Canopus::Error, "snippet format nesting exceeds #{Canopus::Snippet::MAX_DEPTH}" if depth > Canopus::Snippet::MAX_DEPTH
    nodes, literal = [], +""
    until scanner.eos? || endings.include?(scanner.peek(1))
      character = scanner.getch
      if character == "\\" && scanner.peek(1).match?(/[\\\/$}:]/)
        literal << scanner.getch
      elsif character == "$"
        braced = !!scanner.scan(/\{/)
        number = scanner.scan(/\d+/)
        unless number
          raise Canopus::Error, "invalid snippet transform capture" if braced
          literal << "$"
          next
        end
        raise Canopus::Error, "snippet capture index is too large" if number.length > 7 || number.to_i > 1_000_000
        nodes << literal.freeze unless literal.empty?
        literal = +""
        operation, positive, negative = :capture, [], []
        budget[0] += 1
        raise Canopus::Error, "too many snippet format captures" if budget[0] > Canopus::Snippet::MAX_NODES
        if braced && scanner.scan(/:/)
          operation_start = scanner.pos
          case scanner.getch
          when "/"
            operation = scanner.scan(/[a-z]+/)
            raise Canopus::Error, "unsupported snippet case conversion" unless CASES.include?(operation)
          when "+"
            operation = :if
            positive = parse_format(scanner, ["}"], depth + 1, budget)
          when "?"
            operation = :conditional
            positive = parse_format(scanner, [":", "}"], depth + 1, budget)
            raise Canopus::Error, "snippet conditional requires ':'" unless scanner.getch == ":"
            negative = parse_format(scanner, ["}"], depth + 1, budget)
          when "-"
            operation = :else
            negative = parse_format(scanner, ["}"], depth + 1, budget)
          else
            scanner.pos = operation_start
            operation = :else
            negative = parse_format(scanner, ["}"], depth + 1, budget)
          end
        end
        raise Canopus::Error, "unclosed snippet transform format" if braced && scanner.getch != "}"
        nodes << Format.new(number.to_i, operation, positive.freeze, negative.freeze)
      else
        literal << character
      end
    end
    nodes << literal.freeze unless literal.empty?
    nodes.freeze
  end

  def initialize(pattern, replacement, flags)
    raise Canopus::Error, "unsupported snippet transform flags: #{flags}" unless flags.match?(/\A[gimsu]*\z/) && flags.chars.uniq.length == flags.length
    raise Canopus::Error, "snippet transform pattern is too large" if pattern.bytesize > 65_536
    @pattern, @flags, @replacement = pattern.freeze, flags.freeze, replacement
    # Reject Ruby-only syntax and constructs with incompatible JS semantics.
    translated, in_class, scanner, groups = +"", false, StringScanner.new(pattern), []
    until scanner.eos?
      character = scanner.getch
      if character == "\\"
        following = scanner.getch
        raise Canopus::Error, "incomplete snippet regular expression escape" unless following
        raise Canopus::Error, "unsupported snippet regular expression escape: \\#{following}" if following.match?(/[AGKRXZzghkpPc1-9]/) || (following == "u" && flags.include?("i"))
        translated << case following
        when "s" then in_class ? SPACE : "[#{SPACE}]"
        when "S" then "[^#{SPACE}]"
        when "b" then in_class ? "\\b" : '(?:(?<=\w)(?!\w)|(?<!\w)(?=\w))'
        when "B"
          @nonword_boundary = true unless in_class
          in_class ? "B" : '(?:(?<=\w)(?=\w)|(?<!\w)(?!\w))'
        else character + following
        end
      else
        if !in_class && ((character == "(" && scanner.peek(1) == "?" && !scanner.rest.match?(/\A\?(?:[:=!]|<[=!])/)) || (character.match?(/[*+?}]/) && scanner.peek(1) == "+"))
          raise Canopus::Error, "unsupported snippet regular expression construct"
        end
        raise Canopus::Error, "unsupported snippet character-class intersection" if in_class && character == "&" && scanner.peek(1) == "&"
        if !in_class && character == "("
          capture = scanner.peek(1) != "?"
          groups.map! { |parent| parent || capture }
          groups << capture
          raise Canopus::Error, "snippet regular expression nesting exceeds #{Canopus::Snippet::MAX_DEPTH}" if groups.length > Canopus::Snippet::MAX_DEPTH
        elsif !in_class && character == ")"
          captures = groups.pop
          raise Canopus::Error, "captures inside repeated groups are not portable" if captures && scanner.peek(1).match?(/[*+{]/)
        end
        translated << case character
        when "[" then if in_class then "\\[" else in_class = true; character end
        when "]" then in_class = false; character
        when "^" then in_class ? character : flags.include?("m") ? '(?:\A|(?<=[\r\n\u2028\u2029]))' : '\A'
        when "$" then in_class ? character : flags.include?("m") ? '(?=\z|[\r\n\u2028\u2029])' : '\z'
        when "." then !in_class && !flags.include?("s") ? "[^\\n\\r\\u2028\\u2029]" : character
        else character
        end
      end
    end
    options = (flags.include?("i") ? Regexp::IGNORECASE : 0) | (flags.include?("s") ? Regexp::MULTILINE : 0)
    @regexp = Regexp.new(translated, options, timeout: TIMEOUT)
    freeze
  rescue RegexpError => error
    raise Canopus::Error, "invalid snippet regular expression: #{error.message}"
  end

  def apply(value)
    raise Canopus::Error, "snippet transform input exceeds output limit" if value.bytesize > Canopus::Snippet::MAX_OUTPUT
    astral = value.match?(/[\u{10000}-\u{10ffff}]/) || @pattern.match?(/[\u{10000}-\u{10ffff}]/)
    raise Canopus::Error, "astral Unicode snippet transforms require the 'u' flag" if astral && !@flags.include?("u")
    raise Canopus::Error, "\\B with astral Unicode is not portable between JavaScript and Ruby" if astral && @nonword_boundary
    if @flags.include?("i") && [value, @pattern].any? { |source| source.each_char.any? { |character| !character.ascii_only? && ((folded = character.downcase(:fold)).length != 1 || folded.ascii_only?) } }
      raise Canopus::Error, "Unicode case folding into ASCII or multiple characters is not portable"
    end
    output, cursor, count, matched = +"", 0, 0, false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
    Canopus.with_regexp_timeout(@regexp) do
      value.to_enum(:scan, @regexp).each do
        match = Regexp.last_match
        matched = true
        count += 1
        raise Canopus::Error, "snippet transform exceeded execution limit" if count > Canopus::Snippet::MAX_NODES || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        first, last = match.byteoffset(0)
        append(output, value.byteslice(cursor...first))
        append(output, format(@replacement, match))
        cursor = last
        break unless @flags.include?("g")
      end
    end
    return format(@replacement, nil) if !matched && fallback?(@replacement)
    append(output, value.byteslice(cursor..))
    output
  rescue Regexp::TimeoutError
    raise Canopus::Error, "snippet regular expression timed out"
  end

  private

  def append(output, text)
    raise Canopus::Error, "snippet transform exceeds output limit" if output.bytesize + text.bytesize > Canopus::Snippet::MAX_OUTPUT
    output << text
  end

  def fallback?(nodes)
    nodes.any? { |node| node.is_a?(Format) && ([:else, :conditional].include?(node.operation) || fallback?(node.positive) || fallback?(node.negative)) }
  end

  def format(nodes, match)
    nodes.each_with_object(+"") do |node, output|
      if node.is_a?(String)
        append(output, node)
        next
      end
      value = (match && node.index < match.length ? match[node.index] : nil).to_s
      replacement = case node.operation
      when :capture then value
      when :if then value.empty? ? "" : format(node.positive, match)
      when :conditional then format(value.empty? ? node.negative : node.positive, match)
      when :else then value.empty? ? format(node.negative, match) : value
      when "upcase" then value.upcase
      when "downcase" then value.downcase
      when "capitalize" then value.sub(/\A./m) { |first| first.upcase }
      when "camelcase", "pascalcase"
        words = value.scan(/[\p{L}\p{N}]+/)
        words.each_with_index.map { |word, index| word.sub(/\A./m) { |first| index.zero? && node.operation == "camelcase" ? first.downcase : first.upcase } }.join
      when "snakecase" then value.gsub(/([\p{Ll}\d])([\p{Lu}])/, '\1_\2').gsub(/[\s-]+/, "_").downcase
      when "kebabcase"
        value.gsub(/([\p{Lu}]+)([\p{Lu}][\p{Ll}])/, '\1-\2').gsub(/([\p{Ll}\d])([\p{Lu}])/, '\1-\2').gsub(/[^\p{L}\p{N}]+/, "-").sub(/\A-/, "").sub(/-\z/, "").downcase
      end
      append(output, replacement)
    end
  end
end
