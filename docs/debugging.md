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
