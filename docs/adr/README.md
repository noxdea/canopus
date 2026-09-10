# Architecture decision records

This directory records durable implementation choices made between credible
alternatives. Operational workflow, release policy, command syntax, detailed
formats, test evidence, benchmark results, and migration procedures belong in
the relevant reference or design document.

ADR filenames and headings use a gap-free three-digit sequence beginning with
`001`. Create new records with this template:

```markdown
# ADR NNN: Implementation decision title

- Status: Proposed
- Date: YYYY-MM-DD

## Context

Describe the concrete implementation question and its compatibility, data,
runtime, or component constraints. Operational workflow and release policy do
not belong in this directory; see [the scope](README.md).

Name the credible alternatives. If there was no meaningful alternative, record
the behavior in reference documentation instead of creating an ADR.

## Decision

Describe the durable boundary or architecture choice. Leave command syntax,
field-by-field formats, test evidence, benchmark results, and migration steps
in their authoritative documents.

## Consequences

Describe the important positive and negative trade-offs, including what would
make this decision worth revisiting.
```
