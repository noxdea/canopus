# frozen_string_literal: true

# Requires explicit trust plus the read_buffer permission. Works in either mode.
register_action("sample.word_count", description: "Count words in the current buffer") do |api|
  text = api.text
  api.notify("#{text.scan(/\S+/).length} words, #{text.length} characters")
end

register_panel("Word count", side: :right) do |api|
  "Words: #{api.text.scan(/\S+/).length}"
end
