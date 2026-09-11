# ADR 006: Release buffers after their last live view

- Status: Accepted
- Date: 2026-09-11

## Context

A buffer can be shown by editors in several panes and by a project-search
`MultiBuffer`. Closing one tab must dispose its editor subscriptions without
closing language-server documents or persistent ropes still used elsewhere.
The alternatives were an independent reference-counting store or deriving
owners from the workspace's existing editor and excerpt collections.

## Decision

Dispose the editor immediately, then derive the remaining owners from panes and
`MultiBuffer` excerpts in the same close operation. Release the buffer and its
language-server document only when no owner remains. Keep closed-tab navigation
state in a bounded, process-local stack; never retain discarded buffer content.

## Consequences

Ownership has one source of truth and cannot drift through unmatched increment
or decrement calls. The scan is linear in open views; revisit with explicit
owner IDs only if measured close latency becomes material.
