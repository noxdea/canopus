---
layout: guide
title: Git workflow
description: Review changes, stage files or hunks, commit, and synchronize a repository.
---

Open a project inside an existing Git repository. Use the command palette
(**Cmd-Shift-P** or **Ctrl-Shift-P**) and choose `panel.scm` to open the
**Source Control** panel. It groups files into **Staged**, **Changes**, and
**Untracked**.

Canopus operates on the repository's real index and working tree. Changes made
with an external Git client appear as the repository is refreshed.

## Review and commit a change

1. Edit a file and save it. Whole-file staging reads the version on disk.
2. In Source Control, select the file under Changes or Untracked. A single
   click opens its diff.
3. Review the change, then choose **Stage File** (`git.stage`) in the command
   palette. Double-clicking the file in Source Control also stages it.
4. Select the file under Staged to check what the commit will contain.
5. Enter a message in the panel's **Commit message** field and click **Commit**,
   or choose **Commit Staged Changes** (`git.commit`).
6. Wait for the status message showing the created commit's short ID.

To remove a selected staged file from the next commit, choose **Unstage File**
(`git.unstage`) or double-click its entry under Staged. This updates the index
without discarding the working file.

Git needs an author and committer identity. If it is missing, configure your
repository with your own details in the terminal:

```sh
git config user.name "Your Name"
git config user.email "you@example.com"
```

The **Amend** checkbox replaces the current commit. Review the staged content
and message before using it, especially if that commit has already been shared.
Committing requires a branch rather than a detached HEAD.

## Stage only part of a file

1. Select an unstaged file in Source Control to open its SCM diff.
2. Place the cursor within a change and choose **Stage Hunk** (`git.stage_hunk`),
   or on a changed line and choose **Stage Line** (`git.stage_line`).
3. Open its Staged diff to review the portion selected for the commit.
4. Use **Unstage Hunk** or **Unstage Line** in that staged diff if needed.

Diff gutter controls perform the same actions. Partial staging requires an SCM
diff; `git.diff` opens a separate read-only diff for the active file and does not
provide partial staging. Binary files, submodules, and merge-conflicted files
cannot be partially staged. If the file or index changes while a diff is open,
reopen the diff before trying again.

Click a change mark in the editor's gutter, or run `git.toggle_hunk`, to show an
inline preview. `git.revert_hunk` replaces the hunk at the cursor with its HEAD
version as an unsaved buffer edit; review it before saving. Normal text undo
can reverse that buffer edit.

## Inspect history and branches

| Palette action | Command ID | Use |
| --- | --- | --- |
| Show Commit History | `git.history` | Browse commits and select an entry for comparison. |
| Show File History | `git.file_history` | Browse history for the active file. |
| Compare Git Revisions | `git.compare_revisions` | Compare revisions using the prompted references. |
| Toggle Inline / Side-by-Side Diff | `git.diff.toggle_mode` | Change the comparison presentation. |
| `git.blame` | `git.blame` | Show attribution for the active file. |
| `git.branches` | `git.branches` | Select an existing branch to check out. |

Save or discard all unsaved buffer edits before switching branches. Configure
inline blame with `git.inline_blame` set to `off`, `cursor`, or `all`.

## Fetch, pull, and push

Use **Fetch from Remote** (`git.fetch`) to update remote information.
**Pull from Remote** (`git.pull`) updates the working tree; save or discard all
unsaved edits first. **Push to Remote** (`git.push`) sends the current branch to
the same branch name on the selected remote. Push requires an attached branch.

Canopus selects `origin` when present, otherwise the only configured remote.
With several remotes and no `origin`, it asks which remote to use. Configure
remotes using Git in the terminal if the repository has none.

Transfers run in the background and report progress in the message/status
area. **Cancel Git Transfer** (`git.cancel_transfer`) requests cancellation.
HTTPS transfers use the Git credential helper when available; an authentication
failure may open a username and password/token prompt.

Automatic fetching is disabled by default. To fetch every three minutes:

```jsonc
{
  "git": {
    "inline_blame": "cursor",
    "autofetch": true,
    "autofetch_interval": 180
  }
}
```

The interval is in seconds. Automatic fetching does not automatically pull or
push.

## Resolve a merge conflict

Choose **Resolve Merge Conflicts** (`git.conflicts`) to open the next conflict.
Canopus shows base, ours, and theirs in separate panes. For each conflict,
choose **Use ours**, **Use theirs**, or **Use both**. **Use both** places ours
before theirs. To write a custom result, edit the ours pane and choose
**Use manual edit**.

The equivalent command IDs are `git.conflict.ours`, `git.conflict.theirs`,
`git.conflict.both`, and `git.conflict.manual`. Repeat until no conflicts remain,
then review the Source Control state and commit the result.

Binary conflicts, differing encodings, conflicts exceeding 1 MiB or 2,000 lines,
and unsupported line separators can require choosing a complete side. Follow
the reason displayed by the editor.

## When to use the terminal

Git support targets SHA-1 repositories and does not implement every index or
object extension. Use your normal Git CLI for operations that Canopus does not
expose, or if its repository support rejects your repository format. Save edits
before commands that replace working files and review the refreshed state
afterward.
