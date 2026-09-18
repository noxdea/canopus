# Diagnostics

Profiling and crash reports are opt-in:

```sh
ruby --yjit exe/canopus --profile /tmp/canopus-profile.json example.rb
ruby --yjit exe/canopus --profile /tmp/canopus-allocations.json \
  --trace-allocations example.rb
ruby exe/canopus --crash-report /tmp/canopus-crash.json example.rb
```

`--profile` records bounded frame timings, Ruby allocation counts, stack samples,
runtime details, and native draw counts when available. `--trace-allocations`
also summarizes locations of live traced objects, but can substantially increase
memory use and frame time. Missing native counters are reported as `null`.

`--crash-report` writes only after a handled Ruby exception. It includes a bounded
message, backtrace, cause chain, and runtime/rendering context. It does not include
environment variables, command-line arguments, buffers, project files,
screenshots, or arbitrary object values, and nothing is uploaded. Messages and
backtraces can still contain local paths or sensitive text, so review reports
before sharing them. Native crashes and process termination cannot reliably be
captured by this hook.

Use an existing private directory and a distinct filename for each report.
Symlinks and paths overlapping selected input or configuration files are rejected.
On macOS and Linux reports request mode `0600`; Windows users should choose a
private directory with appropriate ACLs.

Developers can produce current, reproducible measurements with:

```sh
BUDGET=1 ruby bench/require.rb
```

The require-only budget is 300 ms in a fresh Ruby process. It covers the
library load, not window creation or the first rendered frame; those remain
measured by the startup benchmark below.

```sh
ruby --yjit bench/frame_profile.rb --frames 120 --output /tmp/frames.json
ruby --yjit bench/minimap.rb
ruby bench/startup.rb --runs 3
ruby --yjit tools/native_check.rb --idle /tmp/native-check.png
```

Compare results only when the platform, renderer, viewport, Ruby/JIT mode,
warmup, and diagnostic options match. Headless software rendering is a regression
check, not a hardware-GPU performance result.

Bracket colors and indentation guides are requested and cached by visible source
rows. Structural analysis stays in the bounded language worker; files on the
large read-only path skip these decorations instead of scanning on the UI thread.

`bench/minimap.rb` renders a 10,000-line file through the real headless renderer.
It asserts the per-frame cold-generation bound, texture reuse while scrolling,
one-row regeneration after an edit, and warm p95 against a same-run minimap-off
baseline. Compare raw timings only on the same Ruby, font, scale factor, and renderer.
