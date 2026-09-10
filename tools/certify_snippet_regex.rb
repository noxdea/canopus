# frozen_string_literal: true

# Development oracle only. Node is never required by Canopus at runtime.
require "json"
require "open3"
require_relative "../lib/canopus"

patterns = ["", "a", ".", ".*", "^", "$", "^.$", "^a", "a$", '[a-z]+', '[^a]', '(a)?', '(a+)(b*)',
  '(?=a)', '(?<=a)b', '(?:a|b)+', '\d+', '\w+', '\s+', '\S+', '\b', '\B', '[a\s]', '[\S]', '[a[b]']
flags = ["", "g", "i", "gi", "m", "gm", "s", "gs", "u", "gu", "ims", "gimsu"]
values = ["", "a", "A", "ab", "aab", "abc123", "aa\nbb", "a\r\nb", "a\rb", "\n", "日本", "a日本b",
  "\u00a0", "x\ufeffy", "a\u2028b", "a\u2029b", "😀", "a😀b"]
cases = patterns.product(flags, values).reject { |pattern, options, value| (!options.include?("u") || pattern == '\B') && value.match?(/[\u{10000}-\u{10ffff}]/) }
javascript = <<~JS
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', part => input += part);
  process.stdin.on('end', () => {
    const result = JSON.parse(input).map(([pattern, flags, value]) =>
      Buffer.from(value.replace(new RegExp(pattern, flags), (...args) => {
        const captures = args.slice(0, -2);
        return [0, 1, 2].map(index => '[' + (captures[index] || '') + ']').join('');
      })).toString('base64')
    );
    process.stdout.write(JSON.stringify(result));
  });
JS
output, error, status = Open3.capture3("node", "-e", javascript, stdin_data: JSON.generate(cases))
abort error unless status.success?
expected = JSON.parse(output).map { |encoded| encoded.unpack1("m0").force_encoding(Encoding::UTF_8) }
cases.each_with_index do |(pattern, options, value), index|
  snippet = Canopus::Snippet.new("${VALUE/#{pattern}/[$0][$1][$2]/#{options}}", variables: {"VALUE" => value})
  abort "Mismatch #{cases[index].inspect}: expected #{expected[index].inspect}, got #{snippet.text.inspect}" unless snippet.text == expected[index]
end
puts "Certified #{cases.length} snippet transform cases against JavaScript RegExp (#{patterns.length} patterns, #{flags.length} flag combinations, #{values.length} inputs)."
