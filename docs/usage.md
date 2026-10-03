---
layout: guide
title: Editing and navigation
description: Find files, edit text, search a project, arrange panes, and run a shell.
---

Open a project with `canopus --project .`. The shortcuts below are the defaults;
[custom keymaps](configuration.md#customize-key-bindings) can change them.

## Open and organize files

Use **Cmd-P** on macOS or **Ctrl-P** on Linux and Windows to find a file by name.
Type a query, select a result, and press Enter. The project explorer also opens
files when selected. **Cmd-B** or **Ctrl-B** toggles the explorer.

| Action | macOS | Linux / Windows |
| --- | --- | --- |
| New document | Cmd-N | Ctrl-N |
| Save | Cmd-S | Ctrl-S |
| Close current tab | Cmd-W | Ctrl-W |
| Reopen a closed, saved tab | Cmd-Shift-T | Ctrl-Shift-T |
| File finder | Cmd-P | Ctrl-P |
| Command palette | Cmd-Shift-P | Ctrl-Shift-P |

Use `tab.pin` in the command palette to pin a tab. The `tab.close_others`,
`tab.close_right`, `tab.close_saved`, and `tab.close_all` commands help clean up
a busy pane. Closing a dirty tab prompts you to save, discard, or cancel by
default.

The project commands `project.new_file`, `project.new_folder`, `project.rename`,
and `project.trash` create and organize files. Enter paths relative to the
project root. New entries require their parent directory to exist. Deletion
moves entries into `.canopus/trash`; move an entry back to recover it.

## Edit with selections and multiple cursors

Select text by dragging or using Shift with cursor keys. Cut, copy, and paste
use the usual platform shortcuts. Undo uses **Cmd-Z** or **Ctrl-Z**; redo uses
**Cmd-Shift-Z** or **Ctrl-Shift-Z**.

To change repeated text:

1. Select a word or text fragment.
2. Press **Cmd-D** or **Ctrl-D** to add its next occurrence.
3. Repeat to select more occurrences, then type the replacement.
4. Use undo if you need to revert the edit.

**Cmd-Shift-L** or **Ctrl-Shift-L** selects all occurrences. **Ctrl-Alt-Up** and
**Ctrl-Alt-Down** add a cursor on an adjacent line. The command palette also
offers **Add Cursors to Line Starts**, **Add Cursors to Line Ends**, and
**Select All Regular Expression Matches**.

| Action | Shortcut |
| --- | --- |
| Move selected lines | Alt-Shift-Up / Alt-Shift-Down |
| Expand or shrink selection | Alt-Up / Alt-Down |
| Toggle a line comment | Cmd-/ on macOS; Ctrl-/ on Linux and Windows |
| Indent / outdent | Commands `edit.indent` / `edit.outdent` |

Automatic brackets and quotes use the configured `auto_pairs`. See
[Snippets](snippets.md) for placeholder-based insertions and [Vim mode](vim.md)
for modal editing.

## Search and replace

Press **Cmd-F** or **Ctrl-F** to search the current document. Enter a query and
press Enter to select the first match. While the search prompt is open,
**Ctrl-Alt-R** toggles regular expressions, **Ctrl-Alt-C** toggles case matching,
**Ctrl-Alt-W** toggles whole words, and **Ctrl-Alt-S** limits the search to the
selection you made before opening the prompt.

For replacements, press **Cmd-Alt-F** on macOS or **Ctrl-H** on Linux and Windows.
Enter the search text and press Enter, then enter the replacement and press
Enter again. This replaces all matches in the document or selected range as
unsaved edits. Undo restores text changes.

To search the project, press **Cmd-Shift-F** or **Ctrl-Shift-F**. Enter the query
and press Enter. The same regex, case, and whole-word toggles apply. Results open
as excerpts from matching files. You can edit the
excerpts directly; **Save writes the changed source files**. Review those edits
before saving. Project search follows Git and project ignore rules.

## Navigate code

| Action | Shortcut / command |
| --- | --- |
| Completion | Ctrl-Space |
| Go to definition | F12 |
| Find references | Shift-F12 |
| Rename a symbol | F2 |
| Code actions | Alt-Enter |
| Document outline | Cmd-Shift-O / Ctrl-Shift-O |
| Workspace symbols | Cmd-T / Ctrl-T |
| Hover information | Cmd-K / Ctrl-K |

Language-specific results depend on the installed server and its capabilities.
See [Language servers](lsp.md) for configuration. Open `panel.problems` to review
diagnostics; `problems.filter` opens a filter that accepts text and terms such
as `severity:error source:lsp`.

## Work in two panes

1. Open the first file.
2. Press **Cmd-Backslash** or **Ctrl-Backslash** (`pane.split_right`).
3. In the new pane, open the second file with the file finder.
4. Click either pane to focus it, or run `pane.next`.

`pane.split_down` stacks panes vertically. `pane.close` closes a pane's tabs,
with the normal unsaved-change prompts.

To restore tabs, cursors, and pane layout between launches, specify a session
file:

```sh
canopus --project . --session .canopus/session.json
```

Use the same option next time. Canopus restores an existing session file and
saves it when the editor exits. Sessions can contain unsaved draft text; keep
the file private if your project contains sensitive content.

## Run commands in the terminal

Press **Ctrl-Backtick** to open the integrated terminal. Click the terminal and
run your project's usual shell commands, then click the editor to continue
editing. New terminals start at the project root by default; later terminals
can inherit the active terminal's reported working directory.

| Action | Shortcut / command |
| --- | --- |
| New terminal tab | Ctrl-Shift-Backtick |
| Next / previous terminal | Ctrl-Shift-] / Ctrl-Shift-[ |
| Copy / paste on macOS | Cmd-C / Cmd-V |
| Copy / paste on Linux and Windows | Ctrl-Shift-C / Ctrl-Shift-V |
| Close focused terminal | Cmd-W / Ctrl-W |
| Split focused terminal | **Split Terminal Right** / **Split Terminal Down** |

Closing a terminal with a running process prompts for confirmation by default.
Multiline pastes also prompt before being sent to the shell.

Bash, zsh, and fish load shell integration for command status, working-directory
tracking, and collapsible output. Click a command's status badge to fold its
output, or use **Show Terminal Commands**, **Show Failed Terminal Commands**,
and **Toggle Terminal Command Output** from the command palette. Disable this
integration with `terminal.shell_integration: false` if needed.

Use [Tasks](tasks.md) for repeatable project commands and [Test explorer](testing.md)
for discovering and running Ruby tests. [Debugging](debugging.md) covers launch
configurations and breakpoints.
