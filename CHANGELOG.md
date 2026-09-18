# Changelog

## Unreleased

- Track shell commands and working directories through Tarazed OSC 133/7 integration, fold output, show exit status, and navigate command boundaries or failed commands.
- Split the terminal panel horizontally or vertically, restore its layout and profiles, and inject editor integration variables.
- Add `--wait` for blocking editor invocations such as `EDITOR="canopus --wait"`.
- Periodically save bounded private snapshots of dirty buffers and offer valid crash recovery on the next startup.
- Require Zaniah 0.5.2 so equal-position inline overlays preserve source order on every platform.
- Delegate language-server protocol transport and lifecycle handling to Sadr.
- Delegate terminal emulation and POSIX/Windows PTY handling to Tarazed; the editor UI is unchanged.
- Delegate project walking and content search to Alkaid while retaining Canopus's search and replace UI.
- Show language-server diagnostics as severity-colored wave underlines and optional line-end messages.
- Collect LSP, task, and test diagnostics in one bounded registry with a filterable Problems panel and status counts.
- Run opt-in formatting and configured source actions before saving without letting language-server failures block the write.
- Route each language through ordered language servers, aggregate completion, diagnostics, and code actions, and restart individual servers.
- Search symbols from every active routed language server with Cmd-T/Ctrl-T and fall back to bounded Alkaid project search.
- Load bounded JSONC debug configurations, expand explicit launch variables, and resolve configured adapters.
- Persist bounded conditional breakpoints with coalesced writes and keep their lines aligned through edits, undo, and redo.
- Toggle breakpoints from the gutter and edit conditions, hit counts, log messages, and enabled state from its context menu.
- Start Megrez-backed debug sessions, configure enabled breakpoints, and highlight safe workspace stop locations.
- Browse stack frames, lazily expand fresh variable paths, reevaluate watches, and list breakpoints in the Debug panel.
- Evaluate selected-frame REPL and hover expressions and show bounded, ordered adapter output in the Debug Console.
- Run bounded JSONC project tasks through Tarazed PTYs in interactive, color-preserving Output tabs.
- Publish bounded single-line, multi-line, and watch task problem matches through the shared diagnostics registry.
- Keep regex-backed task diagnostics responsive on Ruby 3.1 with one deferred complete-line retry before fail-closed disabling.
- Discover bounded Minitest and RSpec declarations with Alkaid and Prism and browse them in the Tests panel.
- Run discovered tests from the gutter, display bounded results, and publish navigable failure diagnostics.
- Preserve registration order for equal-priority decorations across Ruby versions and platforms.
- Show cached, viewport-scoped language-server inlay hints inline with clickable label locations.
- Show cached language-server code lenses above source lines and resolve them only when visible.
- Highlight language-server read, write, and text occurrences for each visible editor caret.
- Prefer language-server folding ranges with asynchronous Antares structure fallback.
- Expand and shrink multiple selections from language-server ranges or asynchronous Antares structure data.
- Validate rename targets asynchronously before opening the dialog when the language server supports preparation.
- Underline and safely open language-server document links, resolving targets only when clicked.
- Turn validated language-server linked ranges into multiple selections from the command palette.
- Browse call and type hierarchies in a lazily loaded side panel.
- Color nested bracket pairs from Antares structure data and draw display-aware active indentation guides.
- Render configurable space, tab, and ideographic-space markers without changing display coordinates.
- Keep the active declaration chain visible with cached LSP symbols and an Antares fallback.
- Navigate files and the cached declaration hierarchy from editor breadcrumbs.
- Add an opt-in GUI minimap with shared, edit-aware line textures and Git, search, and diagnostic overview marks.
- Route LSP, snippet, and extension completion through a bounded provider registry with stable fuzzy ranking.
- Stage Git files, hunks, and lines and create or amend commits from the Source Control panel.
- Compare Git changes and revisions inline or side by side, with word highlights and per-file history.
- Resolve text merge regions in base/ours/theirs panes, stage the completed file atomically, and advance to the next conflict.
- Browse and search bounded commit graphs, run cancellable authenticated remote transfers, and show cached inline blame on clean or edited buffers.

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
