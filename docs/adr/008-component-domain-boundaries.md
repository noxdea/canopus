# ADR 008: Keep one domain in each component repository

- Status: Accepted
- Date: 2026-09-15

## Context

New editor capabilities can live in Canopus, extend an existing component, or
become another independently released gem. Splitting by individual protocol
operation would create small packages that expose each other's internal models;
keeping every capability in Canopus would couple unrelated release cycles.

## Decision

Keep one externally specified or independently testable domain in each
component repository. Extend an existing component when its internal model is
required, and keep product UX and cross-component state ownership in Canopus.
Canopus consumes components through released gems and does not copy their
sources into its repository.

## Consequences

Component APIs and release order remain explicit, and each domain can be tested
headlessly. Coordinated changes require publishing the provider before updating
Canopus. Revisit a split when two components must expose private models to each
other or routinely require lockstep releases.
