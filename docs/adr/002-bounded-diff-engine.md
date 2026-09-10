# ADR 002: Use one bounded diff engine

- Status: Accepted
- Date: 2026-09-10

## Context

Git diffs must have predictable memory use and stable results for large or
repetitive files. Canopus can use a general-purpose diff dependency, switch
algorithms by input size, or apply one bounded implementation to every input.

## Decision

Use the linear-space Myers implementation for every Git diff instead of
switching algorithms by input size.

## Consequences

Memory behavior and tie-breaking remain consistent across file sizes, but
Canopus owns the implementation and its performance limits. Revisit this
decision if a maintained implementation provides the same bounds and stable
results with less maintenance.
