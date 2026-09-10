# ADR 003: Isolate background language analysis in processes

- Status: Accepted
- Date: 2026-09-10

## Context

Language analysis must not block editing, install stale results, or require
`fork`, which is unavailable on native Windows. Work can run in threads sharing
live objects or in portable child processes exchanging serializable data.

## Decision

Run named language-analysis handlers in bounded `Process.spawn` workers that
exchange framed JSON. Install results on the foreground tick only when their
document generation still matches.

## Consequences

Analysis is portable, cancellable, and isolated from mutable editor objects.
Messages cannot carry live Ruby objects and require serialization. Revisit this
decision if process startup or serialization prevents interactive performance.
