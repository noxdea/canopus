---
layout: guide
title: Settings and themes
description: Change user and project settings, themes, key bindings, and save behavior.
---

Settings use JSONC: JSON with comments and trailing commas. Open the command
palette with **Cmd-Shift-P** or **Ctrl-Shift-P**, choose `settings.open`, edit the
project file, and save it. Canopus reloads saved settings while running.

`settings.gui` lists settings and lets you edit their values.
`settings.gui_changed` shows values that differ from the defaults. These
commands write project settings.

## Choose where a setting belongs

| Scope | Location |
| --- | --- |
| User preferences | `$XDG_CONFIG_HOME/canopus/settings.jsonc`, or `~/.config/canopus/settings.jsonc` when that variable is unset |
| Project settings | `.canopus/settings.jsonc` under the project root |
| Explicit settings file | The path passed to `canopus --settings PATH` |
| Language override | An entry under `languages` in a settings file |

For an opened file, later layers override earlier ones:

1. Built-in defaults.
2. User settings.
3. Applicable `.editorconfig` properties, when enabled.
4. Project settings.
5. The explicit `--settings` file and launch overrides such as `--vim`.
6. The file's language override.

Nested objects merge; arrays are replaced. Invalid saved values retain the
previous valid settings. Check the message/status area and the Problems panel
if a change is ignored. A malformed settings file can also prevent startup;
correct its JSONC before relaunching.

## Set editing preferences

This project settings example uses two spaces for Ruby, leaves automatic saving
off, and follows the operating system's light/dark appearance:

```jsonc
{
  "theme": "auto",
  "font_size": 14,
  "tab_size": 4,
  "use_tabs": false,
  "soft_wrap": false,
  "render_whitespace": "boundary",
  "auto_save": "off",
  "languages": {
    "ruby": { "tab_size": 2, "auto_pairs": [] }
  }
}
```

`auto_pairs: []` disables automatic bracket and quote pairing for that language.
`render_whitespace` accepts `none`, `boundary`, `selection`, or `all`.
`font_size` accepts values from 6 to 96 and `tab_size` accepts integers from 1 to
16. `font_family` selects an installed font by family name.

`.editorconfig` is enabled by default. It supports indentation, trimming
trailing whitespace, inserting a final newline, and maximum line length.
Project settings take precedence over these properties. Set `editorconfig` to
`false` to ignore them.

## Select a theme

Use `"Canopus Dark"`, `"Canopus Light"`, or `"auto"` as the `theme` value.
`view.theme` temporarily switches between the built-in dark and light themes;
save a `theme` setting to keep your choice on later launches.

You can also set `theme` to a theme file path relative to the project root.
Canopus imports VS Code JSON/JSONC themes and TextMate `.tmTheme` files.

## Choose save behavior

To save existing editable files after one second without edits:

```jsonc
{
  "auto_save": "after_delay",
  "auto_save_delay": 1000
}
```

The delay is in milliseconds. Other modes are `off` and `on_focus_change`.
Untitled documents still need a path before they can be saved automatically.

Formatting on save requires a language server with formatting support:

```jsonc
{
  "format_on_save": true,
  "format_on_save_timeout": 2000,
  "code_actions_on_save": ["source.organizeImports"]
}
```

Only request code actions your server supports. See [Language servers](lsp.md)
for server commands and save-action behavior. Automatic saving, recovery,
persistent undo, and debug-adapter settings are global and cannot be placed
inside a language override.

Recovery is enabled by default and periodically retains eligible unsaved
drafts in `.canopus/recovery`. Persistent undo is also enabled by default. These
features have storage limits and do not replace saving your files; see
[Getting started](index.md#if-something-does-not-work) for recovery limits.

## Customize key bindings

Choose `keymap.gui` to inspect commands and change bindings, or `keymap.preset`
to select the `vscode`, `sublime`, `jetbrains`, or `emacs` preset.

To assign a shortcut directly, put a `keymap` array in the settings file:

```jsonc
{
  "keymap": [
    {
      "context": "Editor && !vim_mode",
      "bindings": {
        "ctrl-alt-f": "search.project",
        "ctrl-alt-d": "edit.duplicate_line"
      }
    }
  ]
}
```

Bindings use command IDs and normalized names such as `ctrl`, `cmd`, `alt`, and
`shift`. A context restricts where a binding applies; an empty context applies
globally. Set a binding's value to `null` to disable it.

## Configure a terminal profile

For a machine where Bash is installed:

```jsonc
{
  "terminal": {
    "profiles": {
      "bash": { "command": ["bash"], "env": { "PROJECT_ENV": "development" } }
    },
    "default_profile": "bash",
    "working_directory": "project",
    "shell_integration": true
  }
}
```

Use a command available on your platform. Profiles also accept `path` plus
`args`. Canopus sets `CANOPUS=1` and `EDITOR="canopus --wait"` after merging
profile environment variables. Terminal restoration is off by default;
`terminal.restore_on_startup` enables fresh shells from saved session records,
not restoration of running processes.

Continue with [Language servers](lsp.md), [Vim mode](vim.md), [Git workflow](git.md),
or [Plugins](plugins.md) for their specific settings.
