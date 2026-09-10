# Snippets

Canopus accepts [LSP/VS Code snippet syntax](https://code.visualstudio.com/docs/editing/userdefinedsnippets#_snippet-syntax),
including numbered tab stops, nested defaults, mirrors, choices, variables, and
placeholder transforms. Parsing never executes shell commands, Ruby, or
JavaScript.

```text
${1:name} = ${2|value,nil|}$0
${1/(.*)/${1:/upcase}/}
```

Tab and Shift-Tab move between fields. Mirrors update together, leaving a field
applies its transforms, and `$0` ends the session. If `$0` is omitted, Canopus
adds a final caret. Undo, redo, or starting another snippet ends the current
session. Each cursor expands its own snippet and selected-text variables.

Standard filename, workspace, selection, date/time, random, UUID, clipboard, and
language-comment variables are available. Unknown bare variables become editable
placeholders; known but unavailable variables use their default or an empty
string.

Transforms support the portable Ruby/JavaScript regular-expression overlap and
flags `g`, `i`, `m`, `s`, and `u`. Replacement formats include capture references,
case conversion, and conditional/default forms. JavaScript-only features such as
Unicode property escapes and regex backreferences are rejected rather than
silently changed. Ruby code and replacement text are never evaluated.

Snippet source is limited to 1 MiB, expanded text and individual transform output
to 4 MiB, nesting to 32 levels, and regular-expression execution to 50 ms. A
navigation step has a combined 250 ms transform deadline. Exceeding a limit raises
an error before transformed edits are committed.
