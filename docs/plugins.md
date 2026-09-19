# Plugins

Canopus supports two plugin APIs. Existing Ruby plugins use `Workspace#plugins`
and remain available for compatibility. New plugins use the isolated Gienah
host and a `plugin.json` manifest.

```json
{
  "id": "word-count",
  "name": "Word Count",
  "version": "0.1.0",
  "api_version": 2,
  "entry": "plugin.rb",
  "activation": ["onCommand:word-count.refresh"],
  "capabilities": ["buffer.read", "ui.panel"],
  "contributes": {
    "commands": [{"id": "word-count.refresh", "title": "Refresh word count"}],
    "panels": [{"id": "word-count", "title": "Word Count", "dock": "right"}]
  }
}
```

The host discovers manifests without starting processes. A workspace must be
trusted before a manifest is activated. Capabilities are denied by default;
`process.exec`, filesystem, and network access additionally require Saiph.

Plugin entrypoints use Gienah's SDK and communicate with Canopus through the
declared host methods:

```ruby
require "gienah"

Gienah::Plugin.on("ui/event") { |event| Gienah::Plugin.call("workspace/notify", "text" => event["id"]) }
Gienah::Plugin.export("word-count.refresh") do
  text = Gienah::Plugin.call("buffer/text")
  Gienah::Plugin.call("ui/render", "panel" => "word-count", "tree" => {
    "type" => "text", "props" => {"value" => "#{text.split.size} words"}, "children" => []
  })
  nil
end
Gienah::Plugin.run
```

Panels use the allow-listed declarative vocabulary (`column`, `row`, `spacer`,
`scroll`, `divider`, `text`, `icon`, `badge`, `progress`, `code`, `button`,
`checkbox`, `text_field`, `select`, `list`, `tree`, and `section`). Raw colors,
images, fonts, and coordinates are not accepted. UI rendering is cached in the
editor, so a slow plugin cannot block a frame. Completion providers have a
200 ms response budget.

The host also exposes `storage/get`, `storage/set`, `process/exec`,
`net/fetch`, `ui/status`, `ui/quick_pick`, `ui/input`, and `ui/confirm`.
Storage is scoped to the workspace and plugin ID. Network requests must match
the manifest's `net:` host pattern, and dangerous operations remain gated by
the manifest capability and workspace trust.
