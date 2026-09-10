# ADR 005: Run native Windows without requiring YJIT

- Status: Accepted
- Date: 2026-09-10

## Context

The editor must run on macOS, Linux, and native Windows. Requiring YJIT on every
platform conflicts with CRuby builds that do not support it on Windows. The
alternatives are to reject those Windows runtimes, introduce a different JIT,
or allow the supported CRuby interpreter while retaining the same functional
and performance expectations.

## Decision

Require CRuby 3.1 or newer. Attempt to enable YJIT on macOS and Linux, falling
back to the interpreter when the selected Ruby build lacks it. On native Windows,
preserve an already enabled JIT but do not pass an unsupported YJIT flag.

## Consequences

The application can start on native Windows without maintaining another JIT or
excluding the platform. Runtime performance now varies by Ruby build, so results
must identify the engine and JIT state. This does not relax the performance or
native-platform validation requirements. Revisit the decision when official
Windows YJIT support is available or interpreter performance cannot satisfy the
budgets.
