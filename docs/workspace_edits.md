# Language-server file operations

Language servers can request ordered file creation, rename, deletion, and text
edits. Canopus shows every resource-changing request before writing anything.
Apply and Cancel are separate choices, resource operations default to Cancel,
and cancelling reports failure to the server without changing files.

Before confirmation, Canopus validates the complete operation sequence, including
versions and paths produced by earlier operations in the same request. Text edits
remain normal unsaved buffer changes. Renames preserve open buffers; filesystem
operations are not part of text undo history.

Safety rules:

- Targets must be local paths inside the project. Traversal through parent
  symlinks, special files, Git metadata, and the recovery directory is rejected.
- Deletes and overwrites reject dirty or read-only documents. Rename destinations
  must not collide with another open buffer.
- Parent directories must already exist or be created earlier in the same request.
  Deleting a nonempty directory requires an explicit recursive operation.
- A request is limited to 10,000 document operations, 100,000 filesystem entries,
  100,000 text edits, and 32 MiB of inserted text.

Deleted files and overwritten destinations move to `.canopus/trash/lsp-*` with
their original contents and permissions. Backups are not deleted automatically.
If an operation fails, Canopus attempts to reverse completed moves and places new
files in recovery rather than deleting them permanently.

This is not an operating-system transaction. Concurrent external changes,
permission failures, process termination, or callback errors can prevent complete
rollback. Recovery never overwrites an unexpected destination; inspect the
reported recovery paths before restoring files.
