# ADR 010: Apply overlays before display wrapping

- Status: Accepted
- Date: 2026-09-15

## Context

Inline hints occupy space without adding editable buffer bytes, and block
decorations add vertical space without adding source lines. Painting either
after display mapping makes wrapping, cursor placement, selections, and hit
testing disagree with what the user sees. Embedding provider-specific layout in
the workspace view would also bypass the decoration boundary from ADR 009.

## Decision

Make `OverlayMap` a display-map stage and keep the stage order `fold → overlay
→ wrap → tab → block`. The wrap stage accounts for inline width measured from
the active Alhena font, while the final tab projection preserves established
tab-stop output. Block height is represented by non-selectable display rows.
The generic view renders their content through Zaniah text overlays and routes
clicks through the existing decoration action.

Rendered panels, badges, inline overlays, gutter markers, and line highlights
also carry Syrma's public test identifiers. They remain real Zaniah nodes with
their painted bounds; Canopus does not depend on the test driver at runtime.

## Consequences

Buffer offsets remain the only editable coordinates, so overlay content cannot
enter a selection. Changing one decoration rebuilds only its source row. A
block height is rounded up to whole editor rows; sub-row scrolling would require
a pixel-based vertical display coordinate model.
