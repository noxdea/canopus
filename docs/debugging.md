# Debug configurations

Canopus reads project launch configurations from `.canopus/launch.jsonc`. The
file is JSON with comments and trailing commas, parsed by Kochab:

```jsonc
{
  "configurations": [{
    "name": "Run tests",
    "type": "ruby",
    "request": "launch",
    "program": "${workspaceFolder}/bin/rake",
    "args": ["test"],
    "cwd": "${workspaceFolder}"
  }]
}
```

The supported substitutions are `${workspaceFolder}`, `${file}`,
`${lineNumber}`, `${selectedText}`, and `${env:NAME}`. Substitution applies to
all string values, including `program`, `args`, and `cwd`. A requested value
must be available; unknown variables and missing environment entries are
reported as configuration errors. Text inserted from a selection or environment
entry is literal, so `${...}` inside that text is not expanded again. File,
program, and working-directory paths must remain inside the project root.
Adapter commands are accepted only as argument arrays, not as shell command
strings.

Adapters are selected by the configuration's `type` and configured as a global
setting. `languages.*.debug_adapters` is rejected; language selection happens
through each launch configuration's `type`:

```jsonc
{
  "debug_adapters": {
    "ruby": {
      "command": ["rdbg", "--open", "--stop-at-load"],
      "transport": "tcp"
    }
  }
}
```

`transport` is `stdio` or `tcp`. Adapter commands use the same substitutions.
At most 64 adapter types and 32 command arguments per adapter are accepted.
Adapter type names are at most 128 bytes, each command argument is at most
4,096 bytes and contains no control characters, and the complete adapter
setting is at most 1 MiB. These byte limits are enforced at runtime in addition
to the JSON schema's character limits.

Canopus rejects oversized, deeply nested, or incorrectly typed configuration
data before it can start an adapter. Expansion is limited to 1 MiB across one
resolved launch or adapter, and captured environment data is limited to 1 MiB.
If a project has a `Rakefile` but no launch configuration, the configuration
loader offers a `Run tests` launch using `bin/rake test`. Debug sessions and
their user interface are implemented separately from configuration loading.

## Breakpoints

The breakpoint registry stores project-relative paths, 1-based line numbers,
optional conditions, hit conditions, log messages, and enabled state in
`.canopus/breakpoints.json`. Version 1 files are loaded with breakpoints enabled
and are written as version 2 on the next change. The versioned file is
limited to 1 MiB and 10,000 entries. Paths must stay within the canonical
workspace root; paths through outside symlinks are rejected. Breakpoints for
files that are not currently open remain in the registry.

Attached buffers update breakpoint lines after committed edits. Inserting ten
lines before a breakpoint moves it down ten lines, deleting its complete source
line removes it, and undo or redo restores the corresponding registry state.
Tracked edits are coalesced and saved by one background writer; detach and
close flush pending changes and surface write failures. The registry's `error`
accessor exposes the latest background failure, and `flush` re-raises it.
Changes are written through a sibling temporary file followed by `fsync` and
an atomic rename.
This provides normal same-user workspace consistency; concurrent malicious
workspace mutation is outside its scope. Buffer attachment is an internal
lifecycle operation. Left-click the gutter to add or remove a breakpoint.
Right-click it to add or edit a condition, hit count, or log message, or to
enable, disable, and remove the breakpoint. Disabled breakpoints use the muted
gutter color; enabled breakpoints use the error color.

## Sessions

Run `debug.start` from the command palette. If the project has more than one
launch configuration, Canopus opens a searchable configuration list. The
adapter is initialized before enabled breakpoints are sent; Canopus then
completes configuration and waits for the launch or attach response. Only one
session is active per workspace. `debug.stop` closes the protocol session and
its adapter process.

The Ruby TCP adapter example above supports launch configurations and is started
without a shell. Canopus assigns
it a loopback port, passes the resolved `program` and `args` to rdbg, and then
connects with Megrez. TCP attach is not supported; stdio adapters may implement
attach through their launch configuration. On a stop event, the first stack frame is opened only if
its canonical source path remains inside the workspace, and its line is
highlighted. Continued and terminated events clear that highlight. Adapter
startup and protocol failures are delivered through editor notifications.

## Debug panel

The `debug` panel opens automatically when execution stops and is also
available through `panel.debug`. It shows the call stack, variables, watches,
and the persistent breakpoint list. Selecting a stack frame changes the
variable context and opens its source only when the canonical file remains
inside the workspace. Breakpoint rows use the same checked source-opening
path.

Variable children are requested only when their tree row is expanded. The
panel preserves expansion as scope and variable name paths (plus an ordinal
for duplicate sibling names); it never stores adapter `variablesReference`
values in tree state. On another stop or frame selection, Canopus resolves each
saved name path again from fresh scopes before requesting children. Pending
results from a continued, replaced, or closed session are discarded.

Use `debug.watch.add` and `debug.watch.remove` from the command palette to edit
the in-memory watch list. Watches are evaluated with DAP context `watch` for
the selected frame on every stop and whenever the selected stack frame
changes. Watch expressions are limited to 4 KiB and 100 entries. Panel
visibility and size use the existing `dock.panels.debug` setting and session
state; watch expressions themselves are not written to project files.

## Debug console and hover

`debug.console.evaluate` opens the existing input palette and evaluates the
entered expression with DAP context `repl` in the selected stack frame.
`panel.debug_console` toggles the bottom panel. Adapter output events retain
their line breaks and arrival order and show bounded category and source-line
metadata when it is valid. Source metadata is display-only and never opens an
adapter-provided path. Finished sessions retain their history until the next
session starts.

While execution is stopped, hovering an ASCII local, instance, class, or
global variable evaluates it with context `hover`. Bare names are checked
against the selected frame's bounded DAP scopes first. Calls, members,
constants, string and comment tokens, names within a string interpolation
found in up to 256 cached rows or 4,096 tokens, indexing, operators, and names
longer than 256 bytes are not evaluated. Hover and REPL requests are cancelled
on continue, frame change, session replacement, termination, and close; late
results are discarded.
Console history is limited to 1,000 entries, individual adapter strings and
expressions to 4 KiB, and concurrent REPL requests to 16.
