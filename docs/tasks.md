# Tasks

Project tasks live in `.canopus/tasks.jsonc`. Open **Run Task** from the command
palette or press Cmd-Shift-B on macOS / Ctrl-Shift-B on Linux and Windows.

```jsonc
{
  "problem_matchers": {
    "ruby": {
      "owner": "ruby",
      "file_location": ["relative", "${workspaceFolder}"],
      "pattern": {
        "regexp": "^(.+):(\\d+):(?:(\\d+):)?\\s*(warning|error):\\s*(.+)$",
        "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5,
      },
    },
  },
  "tasks": [
    {
      "label": "rake test",
      "command": ["bundle", "exec", "rake", "test"],
      "cwd": "${workspaceFolder}",
      "problem_matcher": "ruby",
      "presentation": { "panel": "output", "reveal": "always" },
    },
  ],
}
```

Commands are argument arrays and are passed directly to `Tarazed::PTY`; Canopus
does not interpolate a shell command string. Each task has one Output tab.
Running the same label again replaces its previous process and tab. Select a
tab and run **Stop Task** (Ctrl-C while its output is focused) to stop only that
task. Output supports terminal colors and interactive input.

The available variables are `${workspaceFolder}`, `${file}`,
`${lineNumber}`, `${selectedText}`, and `${env:NAME}`. Missing variables are
errors. `cwd` and file variables must stay inside the canonical workspace;
symlink escapes are rejected.

`presentation.panel` is currently `output`. `reveal` accepts `always` (show at
start), `silent` (show only after a failing exit), or `never`.

A problem matcher can use one `pattern` object or an array of up to eight
patterns for a multi-line diagnostic. Captures are 1-based and may specify
`file`, `line`, `column`, `end_line`, `end_column`, `severity`, and `message`;
`file`, `line`, and `message` are required across the sequence. Matching files
must already exist inside the canonical workspace. Matches are published with
source `task`, so they appear in editor diagnostics and the Problems panel.

Long-running tasks can add `background` with `begins_pattern`, `ends_pattern`,
and optional `active_on_start`. A begin match starts a fresh cycle and clears
the previous cycle's diagnostics; an end match pauses matching until the next
begin marker. `active_on_start` defaults to `false`.

Task files and expansion are limited to 1 MiB, 128 definitions, and 32 retained
Output tabs. Each PTY uses the configured terminal scrollback and queue limits,
and all output parsing remains frame-budgeted. Matcher lines and unfinished
input are limited to 64 KiB, each matcher retains at most 1,000 diagnostics,
and regular expressions use a timeout. A matcher that times out is disabled for
the rest of that task run while its already-published diagnostics are retained.
On Ruby 3.1, one timeout on a complete line is deferred to the next frame before
disabling, which avoids dropping a matcher after a transient scheduler delay;
an unterminated final line is disabled on its first timeout.
