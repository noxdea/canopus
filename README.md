# Canopus

A Ruby-native code editor built on Zaniah: persistent UTF-8 buffers, native GPU
windows, language-server tools, a terminal, Git inspection, editable project
search results, and Vim bindings.

The launcher requires CRuby 3.1+. It attempts to enable YJIT on macOS/Linux
and falls back to ordinary Ruby when unavailable; Windows uses ordinary Ruby
([runtime decision](docs/adr/005-windows-runtime.md)). OS libraries use Fiddle; language
servers and the terminal shell are user-installed programs. Ruby libraries are
installed as gem dependencies; Prism is bundled with recent Ruby releases.

Native windows need `require "fiddle"` to work in the chosen Ruby installation.
On Ruby distributions that package it separately (including the Ruby 4.0 build
used here), install that standard-library component first. Development Bundler
configuration includes it; headless rendering does not load it.

## Run from this checkout

```sh
bundle install
bundle exec ruby exe/canopus --project . README.md
ruby exe/canopus --headless /tmp/canopus.png README.md
ruby exe/canopus --tui README.md
```

`--help` lists backend, session, settings, replay, cache, and plugin options.
macOS uses Metal, Linux uses Wayland/EGL or X11/GLX, and Windows uses WGL.

Install a local artifact with:

```sh
gem build canopus.gemspec
gem install --local canopus-0.1.0.gem
canopus --project .
```

See [packaging](docs/distribution.md) for desktop bundles and platform
requirements.

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

The palette exposes Git diff/blame/hunk reversal/branch switching, language
actions, project file operations, settings, themes, [Vim mode](docs/vim.md), and docks. Drag tabs
to reorder or move them between panes; drag separators to resize panes and docks.
Project deletion moves files into `.canopus/trash`. Dirty documents and disk
save conflicts are preserved for an explicit decision.

The file finder keeps recent files first and previews text without opening tabs.
Completion supports additional edits and [snippets](docs/snippets.md), including
mirrors, transforms, choices, and Tab / Shift-Tab navigation. Hover cards render
bounded Markdown; only explicitly clicked HTTP(S) links open externally.
Notifications are dismissible and expire automatically.

Project-search results are editable; Save writes changes back to their source
files. Replacement changes remain unsaved until then.

Search palettes use Ctrl-Alt-R for regular expressions, Ctrl-Alt-C for case sensitivity,
Ctrl-Alt-W for whole words and Ctrl-Alt-S for the selection captured when search opened.
Replacements support Ruby backreferences, and stale selections are rejected.
Resource-changing LSP actions show the affected paths before confirmation;
PageUp / PageDown scroll the list. See [workspace edits](docs/workspace_edits.md).

## Settings and extensions

`settings.open` opens `.canopus/settings.jsonc`. User settings live at
`$XDG_CONFIG_HOME/canopus/settings.jsonc` or
`~/.config/canopus/settings.jsonc`. Layers are defaults, user, project, explicit
`--settings`, then language overrides. Saved changes reload; invalid values
preserve the previous valid settings. Ctrl-Space completes setting names.

```jsonc
{
  "theme": "auto",
  "font_size": 14,
  "icon_theme": null,
  "vim_mode": false,
  "use_tabs": false,
  "keymap": [
    { "context": "Editor && !vim_mode", "bindings": { "ctrl-k ctrl-s": "file.save" } }
  ],
  "languages": { "ruby": { "tab_size": 2 } },
  "language_servers": { "ruby": ["ruby-lsp"] }
}
```

See [language servers](docs/lsp.md) for server-specific options and reload
behavior.

Keymap groups extend the defaults; later matching bindings win. Space-separated
keys form a chord with a one-second timeout, and `null` removes a default action
binding. Contexts support `Editor`, `vim_mode`, comparisons and boolean operators,
not Ruby evaluation. Language-specific `keymap` arrays replace the global array.
Saved keymaps reload atomically, including palette labels; invalid expressions
leave the previous settings intact. Limits are 128 groups and 1,024 bindings.

An icon theme is a JSONC file with `file`, `directory`, `expanded_directory`, and
an `extensions` map (for example `".rb": "ruby.svg"`). SVG paths are relative to
that theme file and must remain inside its directory. Only the supported static
SVG subset is drawn; scripts, external references and entities are not executed.

Plugins require explicit trust:

```sh
ruby exe/canopus --plugin examples/plugins/word_count.rb \
  --trust-plugins --grant read_buffer
```

The default separate process contains crashes and timeouts. It is **not an OS
security sandbox**: trusted Ruby retains the invoking user's OS privileges.
API grants restrict the editor bridge, not arbitrary Ruby filesystem/network
access. `--plugins-in-process` opts into direct execution.

## Development and limits

```sh
bundle exec rake test
bundle exec rake bench
bundle exec ruby tools/check_dependencies.rb test/type/smoke.rb
bundle exec rbs -I sig -r alhena -r antares -r denebola -r zaniah -r stringio -r strscan validate
```

Components are Zaniah, Alhena, Denebola, Spica, Kochab and Antares.
Rouge supplies lexers; REXML parses static SVG; unicode-display_width and
unicode-emoji supply terminal-cell tables. They are installed from RubyGems.

Files over 100MiB use a bounded-cache UTF-8 read-only path without wrapping or
folding. Large-file UTF-16/legacy encodings are not supported there. Rouge
lexers that cannot resume exactly use a documented bounded-window fallback,
which can approximate long-distance syntax state. Git supports SHA-1 repositories,
not every Git index/object extension. See the [architecture decisions](docs/adr).

Opt-in [profiling and local crash reports](docs/performance.md) expose real
frame times and allocations without uploading project data.

## License

MIT; see [LICENSE.txt](LICENSE.txt).
