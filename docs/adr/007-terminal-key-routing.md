# ADR 007: Route terminal keys with an explicit editor allowlist

- Status: Accepted
- Date: 2026-09-11

## Context

Terminal applications need control and escape sequences that overlap editor
bindings. Dispatching editor shortcuts first breaks shells, while sending every
key to the PTY makes terminal tab management and application commands
unreachable.

## Decision

When the terminal owns focus, dispatch only bindings whose context matches
`Terminal`; send every unmatched key to the active PTY. Default terminal
bindings cover panel and tab management, copy, paste, and the command palette.
User keymap groups remain later bindings and can override those defaults.

## Consequences

Shell keys pass through by default and `Cmd-W`/`Ctrl-W` close the focused
terminal instead of an editor tab. New global shortcuts must be added to the
terminal context only when interception is intentional.
