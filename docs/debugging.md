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
