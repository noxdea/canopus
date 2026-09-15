# Language servers

Canopus uses separately installed language servers over LSP 3.17. Configure a
server with an argument array or an options object:

```json
{
  "language_servers": {
    "ruby": {
      "command": ["ruby-lsp"],
      "env": {"RUBYOPT": null},
      "initialization_options": {},
      "configuration": {"rubyLsp": {"enabledFeatures": {"diagnostics": true}}}
    }
  }
}
```

`languages.<language>.language_servers.<language>` overrides the global entry.
An absent or `null` entry auto-detects the language's default executable; it does
not disable the server. If no executable is found, Canopus leaves that language
without a server. Invalid settings keep the previous working connection.

Changes to the command, environment, or initialization options restart the
connection and reopen its documents. A configuration-only change sends
`workspace/didChangeConfiguration` without restarting. Resource-changing server
requests require confirmation as described in [workspace edits](workspace_edits.md).

Published diagnostics are shown as severity-colored wave underlines. The most
severe message on each line is also shown at line end by default. Configure this
with `diagnostics.inline`, `diagnostics.inline_max_length`, and the minimum
`diagnostics.severity` (`error`, `warning`, `information`, or `hint`).

Inlay hints are fetched for the visible source lines plus 50 lines of context and
shown inline. Label parts with a server-provided location are clickable. Configure
type and parameter-name hints, or their display limit, with `inlay_hints.types`,
`inlay_hints.parameter_names`, and `inlay_hints.max_length`; set
`inlay_hints.enabled` to `false` to disable requests.

Code lenses are cached for each document version and shown above their source
line. Unresolved lenses are resolved only as they enter the viewport; click a
lens to execute its server command. Set `code_lens.enabled` to `false` to
disable requests and hide cached lenses.

Editor positions use UTF-8 byte offsets internally and are converted to LSP
UTF-16 positions. Servers selecting another position encoding are rejected.
Messages are limited to 32 MiB, crashes fail pending requests, and a connection
is restarted at most three times.

Developers can test installed servers with:

```sh
ruby script/lsp_interop.rb ruby rust typescript go
```
