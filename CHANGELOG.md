# Changelog

## Unreleased

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
