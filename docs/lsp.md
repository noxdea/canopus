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

Configure multiple ordered servers with option objects and explicit feature
routing. The first matching server handles single-result features such as
formatting and definition; completion, diagnostics, and code actions are merged
from every matching server:

```json
{
  "language_servers": {
    "ruby": [
      {"command": ["ruby-lsp"], "features": ["completion", "definition", "hover", "formatting"]},
      {"command": ["rubocop", "--lsp"], "features": ["diagnostics", "codeAction"]}
    ]
  }
}
```

Omit `features` to route from negotiated server capabilities. The legacy
argument array (`"ruby": ["ruby-lsp"]`) remains a single-server command. The
status bar shows each connection, and `language.restart_server` restarts one
selected server without disturbing the others.

Changes to the command, environment, or initialization options restart the
connection and reopen its documents. A configuration-only change sends
`workspace/didChangeConfiguration` without restarting. Resource-changing server
requests require confirmation as described in [workspace edits](workspace_edits.md).

Save-time actions are opt-in and run before the file write. Formatting runs
first, followed by the first enabled action returned for each configured kind:

```json
{
  "format_on_save": true,
  "code_actions_on_save": ["source.organizeImports", "source.fixAll"],
  "format_on_save_timeout": 2000
}
```

The timeout covers the complete sequence. A timeout, stale or invalid edit, or
server failure is reported without preventing the save; edits to the saved
document accepted before a later failure remain grouped as one undo step.
Server edits use the normal version-checked workspace-edit path. Resource
operations are rejected during an automatic save action. An untitled document
establishes its URI on the first Save As, so its save-time actions begin with
the next save.

Published diagnostics are shown as severity-colored wave underlines. The most
severe message on each line is also shown at line end by default. Configure this
with `diagnostics.inline`, `diagnostics.inline_max_length`, and the minimum
`diagnostics.severity` (`error`, `warning`, `information`, or `hint`).

The Problems panel groups validated local-file diagnostics by file and also
accepts task and test sources through the diagnostics registry. Selecting a
problem opens its exact source position. `problems.filter` filters the tree by
free text and optional terms such as `severity:warning` and `source:task`; the
status bar shows current error and warning totals.

Task and test integrations publish the same validated LSP-shaped records with
`workspace.diagnostics.publish(:task, uri, diagnostics)` or `:test`. Publishing
an empty array removes that source's records for the URI.

Inlay hints are fetched for the visible source lines plus 50 lines of context and
shown inline. Label parts with a server-provided location are clickable. Configure
type and parameter-name hints, or their display limit, with `inlay_hints.types`,
`inlay_hints.parameter_names`, and `inlay_hints.max_length`; set
`inlay_hints.enabled` to `false` to disable requests.

Code lenses are cached for each document version and shown above their source
line. Unresolved lenses are resolved only as they enter the viewport; click a
lens to execute its server command. Set `code_lens.enabled` to `false` to
disable requests and hide cached lenses.

When supported, `textDocument/documentHighlight` automatically marks reads,
writes, and textual occurrences at each visible editor's caret. Results are
kept per split and caret, and are discarded when the caret or document changes,
the tab closes, or the language server is replaced.

`textDocument/documentLink` results are underlined and clickable in each visible
editor. Links without a target are resolved only when clicked. Canopus opens
HTTP(S) targets through the platform and local `file` targets in an editor;
remote file URIs and executable or custom URI schemes are rejected. Cached links
and pending resolutions are discarded after edits, hidden tabs, document close,
settings changes, or server replacement.

`editor.fold` prefers cached `textDocument/foldingRange` results and folds the
smallest range containing the caret's source line. Servers without folding
support, null or failed responses, and unconfigured languages fall back to
asynchronous Antares structure analysis; the UI thread never waits for either
source.

`Alt-Up` expands every selection through its nested
`textDocument/selectionRange` chain and `Alt-Down` restores the exact previous
selection. Unsupported, null, failed, or invalid responses fall back to
asynchronous Antares structure analysis. Move-line shortcuts use
`Alt-Shift-Up` and `Alt-Shift-Down`.

`F2` asks servers advertising rename preparation to validate the exact document
version and caret before opening the rename dialog. The prepared range,
placeholder, or client-side identifier pre-fills the dialog; edits, caret moves,
hidden tabs, server replacement, and settings reload cancel the snapshot. Servers
without preparation support, and unconfigured languages, keep the regular rename
dialog.

Run `language.linked_editing` from the command palette to request
`textDocument/linkedEditingRange`. Canopus maps the current primary selection's
relative anchor and caret to every validated, non-overlapping linked range and
creates multiple selections. The request is cancelled when the selection,
document, visible tab, settings, or server changes. Continuous linked editing
and the HTML/XML fallback are intentionally deferred to the later editing-core
work.

Run `language.call_hierarchy` or `language.type_hierarchy` from the command
palette to prepare a hierarchy at the caret. If the server returns more than
one root, choose one from the palette. The right-side Hierarchy panel loads
incoming and outgoing calls, or supertypes and subtypes, only as branches are
expanded. Selecting an item opens its local file and source range; remote file
URIs are rejected.

Sticky scroll prefers `textDocument/documentSymbol` when the server advertises
it and uses cached Antares structure regions otherwise. Requests and normalized
symbol trees are tied to the current buffer version and discarded after edits,
document close, or server retirement; painting never waits for either source.

Editor positions use UTF-8 byte offsets internally and are converted to LSP
UTF-16 positions. Servers selecting another position encoding are rejected.
Messages are limited to 32 MiB, crashes fail pending requests, and a connection
is restarted at most three times.

Developers can test installed servers with:

```sh
ruby script/lsp_interop.rb ruby rust typescript go
```
