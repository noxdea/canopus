# Changelog

## Unreleased

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
