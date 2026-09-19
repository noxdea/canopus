# Changelog

## Unreleased

- Fix Windows terminal reads that could stop before the child process returned output.
- Complete the API v2 plugin host with declarative UI vocabulary, storage, external providers, and trust-aware operations.

## 0.5.0 — 2026-09-19

### Editing and navigation

- Configure automatic pairs and selection surrounding globally or per language, and edit matching HTML/XML tags together when no language server provides linked ranges.
- Add rectangular selection, vertical cursor insertion, and multi-cursor commands for selected line starts, line ends, and regular-expression matches, including wrapped Unicode text.
- Add encoding detection, newline conversion, large-file handling, `.editorconfig` support, automatic save modes, persistent undo, and crash recovery.
- Add breadcrumbs, an optional minimap, whitespace markers, nested bracket colors, active indentation guides, and language-aware folding and selection expansion.
- Add inline diagnostics, inlay hints, code lenses, reference highlights, safe document links, rename preparation, and call/type hierarchies.

### Language tooling and debugging

- Support multiple language servers with merged completion, diagnostics, code actions, workspace symbols, and restart recovery; collect results in a filterable Problems panel and run configured formatting or source actions before saving.
- Add JSONC debug configurations, persistent conditional breakpoints, debug sessions, stack and variable inspection, watches, REPL and hover evaluation, and a Debug Console.

### Terminal, tasks, and tests

- Add shell integration for command boundaries, exit statuses, collapsible output, and working directories, plus split terminal layouts, profiles, and `--wait` for blocking editor invocations.
- Add interactive project tasks with problem matching in Output tabs, test discovery, and gutter-driven test execution with navigable failure diagnostics.

### Git

- Add source-control staging for files, hunks, and lines; commit and amend support; rich diff and merge-conflict views; history and blame; and authenticated remote operations.

### Settings, plugins, and distribution

- Add schema-driven settings editing and diagnostics, keymap presets, workspace trust, and a plugin registry with theme imports and sandboxed plugins.
- Add bundled Ruby to packages together with signed package verification, installers, and update feeds.

## 0.4.0 — 2026-09-15

- Route commands and keybindings through one context-aware command registry.
- Register the explorer, project search, terminal, and plugin panels through one stateful panel registry.
- Supply Git gutter marks and selection highlights through the decoration registry.
- Include inline and block decorations in wrapping, display coordinates, hit testing, and generic rendering.
- Expose rendered panels, badges, and decorations through stable UI test identifiers.

## 0.3.0 — 2026-09-14

- Use the public `Thuban::IgnoreMatcher` and remove Canopus's duplicate implementation.

## 0.2.0 — 2026-09-12

- Read repositories through Thuban and keep text comparison in Porrima data objects.
- Use Porrima marks and indexed hunk lookup for Git gutter interactions.
- Delegate text diff calculation to Porrima without changing Git behavior.
- Add closable editor tabs and multiple terminal tabs with session persistence.
- Prevent duplicate `strscan` initialization in syntax workers.
- Avoid cross-test method replacement in background layout error coverage.

## 0.1.0 — 2026-09-11

- Initial release.
