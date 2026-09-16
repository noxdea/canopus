# Tasks

Project tasks live in `.canopus/tasks.jsonc`. Open **Run Task** from the command
palette or press Cmd-Shift-B on macOS / Ctrl-Shift-B on Linux and Windows.

```jsonc
{
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
start), `silent` (show only after a failing exit), or `never`. Problem matcher
names are retained for the diagnostics integration implemented separately.

Task files and expansion are limited to 1 MiB, 128 definitions, and 32 retained
Output tabs. Each PTY uses the configured terminal scrollback and queue limits,
and all output parsing remains frame-budgeted.
