# Test explorer

Open the **Tests** panel with `panel.test`. Canopus discovers tests in the
background the first time the panel opens. Run `test.refresh` after changing
test declarations; filesystem changes also refresh an explorer that has
already been opened.

Discovery uses Alkaid's workspace walker and the same Git and project ignore
rules as project search. Ruby files in `test/`, ending in `_test.rb`, or named
`test_*.rb` use the Minitest adapter; files in `spec/` or ending in `_spec.rb`
use the RSpec adapter. An explicit `_test.rb` or `_spec.rb` suffix takes
precedence over a containing directory name.
Prism parses each candidate and adapters inspect its AST; comments, strings,
and syntactically invalid files are not treated as tests.

The Minitest adapter recognizes `test_` methods in classes, `test` blocks, and
Minitest spec-style `describe` / `context` groups with `it` or `specify`
examples. The RSpec adapter recognizes nested `describe`, `context`, and
`feature` groups plus their focused and skipped aliases, and `it`, `specify`,
`example`, and `scenario` examples. Test nodes retain only their framework,
workspace-relative path, static name, group path, source position, and bounded
framework selector.
Selecting a test opens its current source line after rechecking that the file
is still a regular file inside the canonical workspace. Each discovered test
also has a gutter button. The marker changes from run to running, passed,
failed, or skipped; clicking it starts that one static test through the shared
Task Output runner. Multiple declarations on one line run together.

Minitest runs use an exact suite/method filter. RSpec combines the discovered
source line with an exact full-description filter. Commands are fixed argument
arrays rather than shell strings. A regular workspace `Gemfile` is run with
`bundle exec`; inherited editor bundle state is
removed before the child starts. Output remains available in the bounded
Output panel and stopping or closing its tab cancels the run.

Failed runs publish a `test` diagnostic and retain a 256 KiB tail of output to
locate the test frame. Selecting a failed test, or its Problems entry, opens
that failure line. If no safe frame is present, Canopus falls back to the
discovered declaration.

Discovery does not follow symlinks. It scans at most 50,000 workspace files,
2,000 candidate test files, and 10,000 tests, with a maximum traversal depth of
64. Candidate files are limited to 1 MiB, names to 4 KiB, and adapter AST walks
to 100,000 nodes per file. Invalid UTF-8, NUL-containing, inaccessible,
oversized, and escaped paths are skipped. Refresh cancels stale work and keeps
at most one discovery worker active; closing the workspace cancels and joins
that worker.

Generating a debug launch remains a separate feature.
