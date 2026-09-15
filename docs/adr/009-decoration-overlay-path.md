# ADR 009: Supply editor overlays through one decoration path

- Status: Accepted
- Date: 2026-09-15

## Context

Git marks and selections were painted directly by the editor view. Diagnostics,
inlay hints, code lenses, debugger state, and plugin overlays would each add
another provider-specific branch to that view. Letting providers draw directly
would also mix invalidation and data ownership with viewport rendering.

## Decision

Providers register bounded suppliers with `Decoration::Registry`. The registry
owns source identity, ordering, caching, and invalidation. The view asks the
registry for the current row range and renders items by decoration kind; click
handlers return through the controller without embedding provider behavior in
the renderer.

## Consequences

Future overlays share one rendering and invalidation boundary, while providers
stay independent of scene construction. The registry contract becomes a public
internal extension point, and display-coordinate-changing inline and block
items still require a separate overlay-aware display map.
