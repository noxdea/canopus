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
ruby --yjit bench/frame_profile.rb --frames 120 --output /tmp/frames.json
ruby bench/startup.rb --runs 3
ruby --yjit tools/native_check.rb --idle /tmp/native-check.png
```

Compare results only when the platform, renderer, viewport, Ruby/JIT mode,
warmup, and diagnostic options match. Headless software rendering is a regression
check, not a hardware-GPU performance result.
