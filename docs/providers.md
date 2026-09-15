# Completion providers

`workspace.providers` combines completion sources without coupling the editor to
a particular language server. Canopus registers LSP completion itself; plugins
and embedders can add sources with `register_completion`:

```ruby
workspace.providers.register_completion(:project_terms, priority: 20) do |buffer, offset, context|
  [Canopus::Provider::Completion.new(
    "ProjectName", "ProjectName", :constant, "Project term", nil,
    nil, nil, [], :project_terms
  )]
end
```

The block runs away from the UI thread and receives the current buffer, UTF-8
byte offset, and a context hash whose `:query` is the word prefix. It returns an
array of `Completion` records, or an awaitable with `await(timeout:)`. Results
are fuzzy-ranked with Spica; higher source priority is the stable tie-break. Duplicate
label/insertion pairs keep the higher-ranked source. Invalid, oversized, or
failed sources are omitted without hiding results from healthy sources. All
sources share a ten-second completion deadline, rather than multiplying that
deadline by the number of registered providers.

Use source `:snippet` (or kind `:snippet`) when `insert_text` contains LSP/
TextMate snippet syntax. Additional edits are `[Range, String]` pairs and are
preflighted with the main insertion before editing.

Ghost-text integrations can register a block with
`register_inline_completion(source)`. `inline_completion(buffer, offset)` uses
the first registered provider that returns a valid non-nil string. Canopus only
provides this boundary today; AI, word, and path providers belong to their
respective later features or plugins.

At most 64 providers of each kind, 10,000 combined completion records, 1,000
additional edits per record, and 64 KiB per string are accepted.
