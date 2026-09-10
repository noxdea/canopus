# ADR 001: Consume released components as runtime gems

- Status: Accepted
- Date: 2026-09-11

## Context

Canopus uses components maintained and released from independent repositories.
It can load them from sibling checkouts, copy their sources into this repository,
combine the repositories, or depend on their released gems. An installed Canopus
gem must not depend on the development directory layout.

## Decision

Keep each component repository as its source and release boundary. Consume its
released gem as a runtime dependency without copying component sources into the
Canopus repository or locating sibling checkouts.

## Consequences

Canopus packages stay small and component fixes follow normal gem releases.
Installations require access to compatible component versions, and coordinated
changes may need multiple releases. Revisit this decision if components can no
longer provide compatible releases independently.
