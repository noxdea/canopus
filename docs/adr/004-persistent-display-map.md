# ADR 004: Store display transforms in one persistent summary tree

- Status: Accepted
- Date: 2026-09-10

## Context

Folding, tab expansion, wrapping, and block inlays all transform buffer
positions into displayed positions. Canopus can maintain separate mutable maps
for each transform or combine their ordered summaries in one persistent tree.

## Decision

Represent Fold, Tab, Wrap, and Block transforms in one persistent summary tree.
Keep hit testing and edits tied to exact buffer ranges while pixel reflow runs
asynchronously.

## Consequences

Transforms share one source of positional truth and snapshots remain cheap.
Updates and queries depend on the combined summary invariants, and asynchronous
reflow can briefly show provisional layout. Revisit this decision if transforms
stop being line-local or the combined tree becomes a measured bottleneck.
