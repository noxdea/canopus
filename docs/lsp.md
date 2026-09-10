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

Editor positions use UTF-8 byte offsets internally and are converted to LSP
UTF-16 positions. Servers selecting another position encoding are rejected.
Messages are limited to 32 MiB, crashes fail pending requests, and a connection
is restarted at most three times.

Developers can test installed servers with:

```sh
ruby script/lsp_interop.rb ruby rust typescript go
```
