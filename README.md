<p align="center">
  <img src="assets/logo.png" alt="Canopus logo">
</p>

<p align="center">
  <strong>Ruby-native code editor with GPU windows, language-server tools, a terminal, Git integration, and Vim bindings</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/canopus"><img src="https://img.shields.io/gem/v/canopus.svg" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/canopus"><img src="https://img.shields.io/gem/dt/canopus.svg" alt="Gem downloads"></a>
  <a href="https://github.com/noxdea/canopus/actions/workflows/main.yml"><img src="https://github.com/noxdea/canopus/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/CRuby-%3E%3D%203.1-cc342d.svg" alt="CRuby 3.1 or newer">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#development">Development</a>
</p>

---

Canopus is a code editor implemented in Ruby. It combines persistent UTF-8
buffers with native rendering through [Zaniah](https://github.com/noxdea/zaniah),
while keeping language servers, shells, and other external tools independently
installable.

## Features

- Native GPU windows on macOS, Linux, and Windows, plus TUI and headless modes
- Persistent buffers, tabs, splits, sessions, and explicit save-conflict handling
- LSP completion, diagnostics, hover, document and workspace symbols, formatting, prevalidated rename, and code actions
- Filterable Problems tree for LSP, task, and test diagnostics, with error and warning status counts
- Automatic read, write, and text highlights for the symbol at each visible editor's caret
- Clickable LSP document links with on-demand resolution and safe HTTP or local-file navigation
- LSP folding ranges with an asynchronous Antares fallback
- LSP-aware selection expansion with an asynchronous Antares fallback
- LSP linked-range selection for starting a multi-cursor edit from the command palette
- Lazy call and type hierarchy trees with bidirectional navigation
- Ranked, extensible completion and inline-completion provider registry
- Viewport-scoped LSP inlay hints with clickable label locations
- Nested bracket colors and active indentation guides backed by Antares structure analysis
- Optional GPU minimap with shared line textures, viewport navigation, and overview markers
- Resizable integrated terminal with multiple tabs, scrollback, selection, colors, and clickable links
- Git diff, blame, hunk reversal, and branch switching
- Editable project-wide search results and safe project file operations
- Optional Vim-compatible modes, motions, operators, registers, macros, and Ex commands
- Layered JSONC settings, keymaps, themes, snippets, and trusted Ruby plugins
- Overlay-aware wrapping and coordinates for inline hints and block decorations
- Rendered panel and decoration nodes expose stable `test_id` conventions for UI tests

## Installation

Install the released gem:

```sh
gem install canopus
canopus --version
```

Canopus requires CRuby 3.1 or newer. The launcher enables YJIT when supported
and otherwise uses the interpreter. Native windows also require the `fiddle`
standard-library component; some Ruby distributions package it separately.

macOS uses Metal. Linux requires Wayland/EGL/OpenGL or X11/GLX, XKB, and
`zenity` for file dialogs. Windows uses WGL. See [Packaging](docs/distribution.md)
for source-based desktop bundles and platform details.

## Quick start

Open the current project:

```sh
canopus --project .
```

Open files directly, use the terminal interface, or render a headless frame:

```sh
canopus README.md lib/canopus.rb
canopus --tui --project .
canopus --headless /tmp/canopus.png README.md
```

Run `canopus --help` for session, settings, replay, backend, profiling, and
plugin options.

## Everyday controls

| Action | macOS | Linux / Windows |
| --- | --- | --- |
| File finder / commands | Cmd-P / Cmd-Shift-P | Ctrl-P / Ctrl-Shift-P |
| Workspace symbols | Cmd-T | Ctrl-T |
| Save / undo / redo | Cmd-S / Cmd-Z / Cmd-Shift-Z | Ctrl-S / Ctrl-Z / Ctrl-Shift-Z |
| Find / project search | Cmd-F / Cmd-Shift-F | Ctrl-F / Ctrl-Shift-F |
| Replace / next occurrence | Cmd-Alt-F / Cmd-D | Ctrl-H / Ctrl-D |
| All occurrences / expand or shrink selection | Cmd-Shift-L / Alt-Up or Down | Ctrl-Shift-L / Alt-Up or Down |
| Move lines | Alt-Shift-Up or Down | Alt-Shift-Up or Down |
| Completion / definition / rename | Ctrl-Space / F12 / F2 | Ctrl-Space / F12 / F2 |
| Split / terminal | Cmd-Backslash / Ctrl-Backtick | Ctrl-Backslash / Ctrl-Backtick |
| Close / reopen tab | Cmd-W / Cmd-Shift-T | Ctrl-W / Ctrl-Shift-T |
| New terminal tab | Ctrl-Shift-Backtick | Ctrl-Shift-Backtick |
| Next / previous terminal | Ctrl-Shift-] / Ctrl-Shift-[ | Ctrl-Shift-] / Ctrl-Shift-[ |

The command palette also exposes Git operations, language actions (including
`language.linked_editing`, `language.call_hierarchy`, and
`language.type_hierarchy`), project file operations, settings, themes, docks,
Vim mode, `panel.problems`, and `problems.filter`. The problem filter accepts
free text plus optional `severity:error` and `source:lsp` terms (`warning`,
`information`, `hint`, `task`, and `test` are also accepted). Project deletion
moves files to `.canopus/trash` instead of deleting them immediately.

## Configuration

Run `settings.open` from the command palette to edit project settings. User
settings live at `$XDG_CONFIG_HOME/canopus/settings.jsonc` or
`~/.config/canopus/settings.jsonc`.

```jsonc
{
  "theme": "auto",
  "font_size": 14,
  "vim_mode": false,
  "use_tabs": false,
  "diagnostics": { "inline": true, "inline_max_length": 80, "severity": "warning" },
  "inlay_hints": { "enabled": true, "parameter_names": true, "types": true, "max_length": 30 },
  "code_lens": { "enabled": true },
  "bracket_colorization": true,
  "indent_guides": { "enabled": true, "active": true },
  "render_whitespace": "boundary",
  "render_ideographic_space": true,
  "sticky_scroll": { "enabled": true, "max_lines": 5 },
  "breadcrumbs": { "enabled": true },
  "minimap": { "enabled": false, "width": 100, "show_diagnostics": true },
  "format_on_save": false,
  "code_actions_on_save": [],
  "format_on_save_timeout": 2000,
  "tabs": { "activate_on_close": "history", "reopen_history_limit": 20 },
  "terminal": { "working_directory": "project", "scrollback_lines": 10000 },
  "dock": {
    "bottom": { "size": 280, "visible": false },
    "panels": { "terminal": { "size": 280, "visible": false } }
  },
  "keymap": [
    { "context": "Editor && !vim_mode", "bindings": { "ctrl-k ctrl-s": "file.save" } }
  ],
  "languages": { "ruby": { "tab_size": 2 } },
  "language_servers": {
    "ruby": [
      { "command": ["ruby-lsp"], "features": ["completion", "definition", "hover", "formatting"] },
      { "command": ["rubocop", "--lsp"], "features": ["diagnostics", "codeAction"] }
    ]
  },
  "debug_adapters": {
    "ruby": { "command": ["rdbg", "--open", "--stop-at-load"], "transport": "tcp" }
  }
}
```

A legacy argument array such as `"ruby": ["ruby-lsp"]` still configures one
server. With multiple servers, completion, diagnostics, and code actions are
merged; workspace symbols are collected from every matching active server;
other features use the first matching server in configuration order. Workspace
symbol search falls back to bounded project-content search when no usable
provider is active. Override `language.workspace_symbols` in `keymap` to change
its Cmd-T / Ctrl-T binding.

`render_whitespace` accepts `none`, `boundary`, `selection`, or `all`.
`boundary` hides only single spaces between non-whitespace characters. Tabs use
`→`, spaces use `·`, and ideographic spaces use `□`; the last remains visible
independently when `render_ideographic_space` is enabled.

Sticky scroll keeps the declarations containing the first visible source byte
above the editor body. It prefers cached LSP document symbols and falls back to
cached Antares structure regions; `sticky_scroll.enabled` and
`sticky_scroll.max_lines` can also be overridden per language.

Breadcrumbs show the project-relative file, containing type, and callable above
sticky scroll. Selecting an item opens its same-directory files or same-parent
symbols in the palette. `breadcrumbs.enabled` can be overridden per language.

The GUI-only minimap is disabled by default. When enabled, it reserves its
configured width only in panes wide enough to keep the editor usable, reuses
bounded low-resolution line textures across splits, and shows Git, search, and
optionally diagnostic overview marks. Click or drag it to center that source
position without moving the selection. All minimap options can be overridden
per language.

Closing a dirty tab asks whether to save, discard, or cancel. Reopening restores
the file, selections, position, and pane while Canopus is running; discarded
unsaved changes are never restored. Dock and panel visibility and sizes are also
restored. Terminal session restoration, when enabled,
starts fresh shells with the saved tab count and working directories and does
not restore processes or scrollback.

Settings are layered from defaults through user, project, explicit `--settings`,
and language overrides. Invalid saved settings leave the previous valid values
active. Keymap groups extend defaults; later matching bindings win, and `null`
removes a default binding.

Language servers are separate programs and are auto-detected or configured by
argument array. See [Language servers](docs/lsp.md) for configuration and
restart behavior.

Plugins require explicit trust and permissions:

```sh
canopus --plugin examples/plugins/word_count.rb \
  --trust-plugins --grant read_buffer
```

The default separate process contains plugin crashes and timeouts, but it is not
an OS sandbox. Trusted Ruby code retains the invoking user's filesystem and
network privileges.

## Documentation

- [Language servers](docs/lsp.md)
- [Debug configurations](docs/debugging.md)
- [Vim mode](docs/vim.md)
- [Snippets](docs/snippets.md)
- [Completion providers](docs/providers.md)
- [Workspace edits](docs/workspace_edits.md)
- [Packaging](docs/distribution.md)
- [Profiling and local crash reports](docs/performance.md)
- [Architecture decisions](docs/adr)

## Development

```sh
git clone https://github.com/noxdea/canopus.git
cd canopus
bundle install
bundle exec rake test
bundle exec rbs -I sig -r porrima -r thuban -r alhena -r antares -r denebola -r zaniah -r sadr -r tarazed -r alkaid -r stringio -r strscan validate
bundle exec ruby tools/check_dependencies.rb test/type/smoke.rb
```

Before component releases are available, use sibling checkouts with
`SADR_PATH=../sadr TARAZED_PATH=../tarazed ALKAID_PATH=../alkaid ANTARES_PATH=../antares bundle install`.

Run `bundle exec rake bench` for performance checks. Contributions can be
submitted through [GitHub issues and pull requests](https://github.com/noxdea/canopus/issues).

## Limits

- Files larger than 100 MiB use a read-only UTF-8 path without wrapping or folding.
- Large-file UTF-16 and legacy encodings are unsupported.
- Git support targets SHA-1 repositories and does not implement every index or object extension.
- The integrated terminal uses a POSIX PTY on macOS/Linux and ConPTY on 64-bit Windows.
- Desktop packages are unsigned and do not bundle Ruby or automatic updates.

## License

Canopus is released under the [MIT License](LICENSE.txt).
