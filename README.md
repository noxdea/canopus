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
- LSP completion, diagnostics, hover, symbols, formatting, rename, and code actions
- Integrated terminal with scrollback, selection, colors, and clickable links
- Git diff, blame, hunk reversal, and branch switching
- Editable project-wide search results and safe project file operations
- Optional Vim-compatible modes, motions, operators, registers, macros, and Ex commands
- Layered JSONC settings, keymaps, themes, snippets, and trusted Ruby plugins

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
| Save / undo / redo | Cmd-S / Cmd-Z / Cmd-Shift-Z | Ctrl-S / Ctrl-Z / Ctrl-Shift-Z |
| Find / project search | Cmd-F / Cmd-Shift-F | Ctrl-F / Ctrl-Shift-F |
| Replace / next occurrence | Cmd-Alt-F / Cmd-D | Ctrl-H / Ctrl-D |
| All occurrences / move lines | Cmd-Shift-L / Alt-Up or Down | Ctrl-Shift-L / Alt-Up or Down |
| Completion / definition | Ctrl-Space / F12 | Ctrl-Space / F12 |
| Split / terminal | Cmd-Backslash / Ctrl-Backtick | Ctrl-Backslash / Ctrl-Backtick |

The command palette also exposes Git operations, language actions, project file
operations, settings, themes, docks, and Vim mode. Project deletion moves files
to `.canopus/trash` instead of deleting them immediately.

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
  "keymap": [
    { "context": "Editor && !vim_mode", "bindings": { "ctrl-k ctrl-s": "file.save" } }
  ],
  "languages": { "ruby": { "tab_size": 2 } },
  "language_servers": { "ruby": ["ruby-lsp"] }
}
```

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
- [Vim mode](docs/vim.md)
- [Snippets](docs/snippets.md)
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
bundle exec rbs -I sig -r alhena -r antares -r denebola -r zaniah -r stringio -r strscan validate
bundle exec ruby tools/check_dependencies.rb test/type/smoke.rb
```

Run `bundle exec rake bench` for performance checks. Contributions can be
submitted through [GitHub issues and pull requests](https://github.com/noxdea/canopus/issues).

## Limits

- Files larger than 100 MiB use a read-only UTF-8 path without wrapping or folding.
- Large-file UTF-16 and legacy encodings are unsupported.
- Git support targets SHA-1 repositories and does not implement every index or object extension.
- Desktop packages are unsigned and do not bundle Ruby or automatic updates.

## License

Canopus is released under the [MIT License](LICENSE.txt).
