# 53 — Resident compiler daemons: what sixteen projects chose and what went wrong

*2026-10-03. Gathered by a research agent for `plans/m4-plan.md` §7's daemon decisions (D6–D9),
findings only; the decisions it informed are recorded there. Four claims were checked against
their sources by the manager: the gopls design quotes, tsserver's protocol and cancellation, and
Turbopack 16.3's eviction held; **one did not** — Rust Glancer was posted to HN by matklad,
rust-analyzer's original author, but its author is someone else (popzxc), which the text below has
been corrected to say. Everything else is unverified beyond the agent's own reading: treat each
claim as a lead with a source.*


## rust-analyzer + salsa

**1. Protocol.** Plain LSP/JSON-RPC; the server is deliberately stateless per-request ("the server is stateless, a-la HTTP" — if context must persist, "the second request should include enough info to re-create the context from scratch", https://rust-analyzer.github.io/book/contributing/architecture.html). A VFS layer gives "consistent snapshots of the underlying file system" and in principle could serve two machines from one process (same URL). Unsaved buffers flow into the VFS via `didChange`; `cargo check`-based features still "only look at saved files from disk, not the editor contents" (https://internals.rust-lang.org/t/allow-running-cargo-check-on-a-virtual-file-system-like-the-one-held-by-rust-analyzer/22709). No client/daemon version skew question arises — it's one binary per editor session, not a shared daemon.

**2. Memory.** No ceiling by default: "keeping everything in memory is OK" (architecture.html) — true for source text, not for all derived data. Salsa ships opt-in per-query **LRU eviction** (`set_lru_capacity(n)`) because plain revision-based GC "is hard to determine which values should be collected… rust-analyzer just periodically clears all values of specific queries" (https://github.com/salsa-rs/salsa-rfcs/blob/master/RFC0004-LRU.md). Salsa's 2023 "durable incrementality" rework replaced a single global revision counter with a durability-tiered vector so one file edit doesn't force re-checking ~300ms of stdlib-related queries every time (https://rust-analyzer.github.io/blog/2023/07/24/durable-incrementality.html).

**3. File watching.** Not deeply documented beyond VFS abstraction; relies on editor/LSP-client file events plus VFS snapshotting rather than a separately documented OS-watcher strategy.

**4. Cancellation.** Salsa keeps a global revision counter; bumping it on edit makes any thread still computing an old revision **panic** with a special value, caught at the IDE boundary and surfaced as `Result<T, Cancelled>` (architecture.html). matklad names this as rust-analyzer's chosen strategy explicitly: "on step 6, when the server becomes aware about the pending edit, it actively cancels all in-flight work… This is the strategy employed by rust-analyzer" (https://matklad.github.io/2023/05/06/zig-language-server-and-cancellation.html). Cooperative/revision-based, not OS-thread kill.

**Problems hit:** chronic high memory, several GB up to OOM on large projects (https://github.com/rust-lang/rust-analyzer/issues/13093, 13807, 21302, 5728, 7439, 8749, 18127, 20917, 20028). HN: "rust-analyzer taking 2GiB of RAM per instance definitely hurts" (https://news.ycombinator.com/item?id=41474069); a thread ties the cause to the query-based in-memory design and spawned a rival project, **Rust Glancer** (by popzxc; posted to HN by matklad, rust-analyzer's original author), targeting <100MB by persisting an index to disk instead of keeping the crate graph resident (https://news.ycombinator.com/item?id=49393052). Unsaved-buffer/`cargo check` staleness is a long-acknowledged VFS limitation (https://users.rust-lang.org/t/rust-analyzer-doesnt-check-the-buffer-on-typing-but-only-on-save-how-to-change-that/79221; https://github.com/helix-editor/helix/issues/11966).

**Changes:** salsa LRU eviction (RFC0004); the 2023 durability-vector rework; Rust Glancer as an alternative disk-backed architecture (not adopted by rust-analyzer core, built as a separate tool).

## gopls

**1. Protocol.** JSON-RPC 2.0 over stdio by default, chosen because "JSON is part of the Go standard library, and is also the native language of LSP", designed from the start to also support sockets (https://go.googlesource.com/tools/+/refs/heads/master/gopls/doc/design/design.md). Daemon mode: each editor spawns a thin "sidecar" gopls that forwards LSP to one shared gopls instance over TCP (`-listen=:37374`) or a Unix socket (https://go.googlesource.com/tools/+/refs/heads/master/gopls/doc/daemon.md). Internally split into **view/session/cache**: session/view hold per-editor-session state (open buffers), the cache is shareable across sessions (same URL). No protocol-version negotiation; instead the daemon socket selection is meant to be environment-hash sensitive so a stale daemon isn't reused across incompatible toolchains (https://github.com/golang/go/issues/37830).

**2. Memory.** Explicitly "stateless across restarts" rather than persistent/evicted: "Persistent disk caches are very expensive to maintain… rebuilding the information when gopls is restarted will be acceptable"; "if it has issues or gets its state confused, a simple restart will often fix the problem" (design.md, same URL). The design doc flags this as a known scaling risk up front, with no LRU/eviction policy — restart is the mitigation.

**3. File watching.** Client-driven by default (`fileWatcher: "off"` relies on `workspace/didChangeWatchedFiles`); `"fsnotify"` and `"poll"` are server-side alternatives (https://github.com/golang/tools/blob/master/gopls/doc/settings.md). Added because files are "often modified outside of the editor" (branch switches, codegen) and gopls previously didn't rebuild on that (https://github.com/golang/go/issues/31553). Client watch-glob registration was reported "too broad" in some integrations (https://github.com/golang/go/issues/41504).

**4. Cancellation.** Not found in primary docs in this pass.

**Problems hit:** daemon/env version skew — "how does gopls in this mode determine which go binary to use? I'm guessing it inherits PATH… which might be wrong" (https://github.com/golang/go/issues/37830). Stale socket discovery: different editor plugins set different `$TMPDIR`, breaking the deterministic-path daemon discovery and spawning redundant daemons (https://github.com/golang/go/issues/41266). Shutdown races on `--remote=auto` during nvim exit (https://github.com/golang/go/issues/51252). Darwin-specific crash just after opening a Unix-socket listener (https://github.com/golang/go/issues/62337). Watch-glob over-matching (https://github.com/golang/go/issues/41504).

**Changes:** plan to incorporate environment variables into the daemon socket-path hash and compare environments at forwarder/daemon handshake (https://github.com/golang/go/issues/37830); shared daemon auto-shuts down after 1 minute idle with no clients (daemon.md); `didChangeWatchedFiles` support added for out-of-editor changes; `fsnotify`/`poll` added as server-side fallbacks.

## TypeScript tsserver

**1. Protocol.** Custom JSON protocol over stdio (header with content-length, `\r\n`, JSON body) — not JSON-RPC (https://github.com/microsoft/TypeScript/wiki/Standalone-Server-(tsserver)). A 2016 proposal to switch to JSON-RPC was never adopted (https://github.com/Microsoft/TypeScript/issues/11423); editors wrap tsserver's protocol in LSP themselves (e.g. vscode-languageserver-node). `open`/`change` commands give unsaved-buffer overlays.

**2. Memory.** No built-in ceiling; VS Code exposes `typescript.tsserver.maxTsServerMemory` to cap it. No LRU/eviction in primary docs — effectively unbounded until OOM.

**3. File watching.** Per-directory `fs.watch`/polling inside tsserver itself, not a shared daemon like Watchman; VS Code has an experimental `useVsCodeWatcher` flag to delegate to its own watcher instead.

**4. Cancellation.** Named-pipe cooperative cancellation: the client generates a pipe name passed to the server as `cancellationPipeName`; for concurrent requests a `*`-templated name is expanded per request id, and the server emits `requestCompleted` so the client can close it (https://github.com/microsoft/TypeScript/wiki/Standalone-Server-(tsserver)). Heavy commands like `geterr` are split into delayed steps "to react on user actions more promptly and not run heavy computations if their results will not be used" (same source).

**Problems hit:** memory blow-ups repeatedly: ~1GB on medium projects (https://github.com/microsoft/TypeScript/issues/46028), ~2GB ceiling while editing (https://github.com/microsoft/TypeScript/issues/18055), 1442MB on a Next.js app (https://github.com/microsoft/vscode/issues/236773), 20.5GB despite `max_old_space_size` (https://github.com/microsoft/vscode/issues/85777), 25GB RAM (https://github.com/microsoft/vscode/issues/91946). inotify exhaustion: 17,061 watches for a few hundred files, mostly `node_modules` (https://github.com/microsoft/TypeScript/issues/33338); 5,000 watches for one file because excludes weren't respected (https://github.com/microsoft/TypeScript/issues/46207); typings-installer hit the OS watch-handle limit (https://github.com/microsoft/TypeScript/issues/41280); VS Code's alternate watcher leaked inotify handles across restarts until exhaustion/hang (https://github.com/microsoft/vscode/issues/214605). Version skew: bundled-vs-workspace TypeScript version selection broke paths/missed errors (https://github.com/microsoft/vscode/issues/105202, 11772); Zed's `vtsls` using bundled instead of workspace version (https://github.com/zed-industries/zed/issues/25652).

**Changes:** exposed a user-settable memory cap (no auto-eviction); added an experimental VS Code-native watcher (which itself leaked); kept iterating exclude/`watchOptions` handling. No evidence the JSON-RPC migration ever landed.

## Sorbet

**1. Protocol.** Standard LSP/JSON-RPC via `srb tc --lsp`, including over SSH by piping stdin/stdout, LSP 3.17 plus Sorbet-specific extensions (`sorbet/showOperation` with phases Indexing/SlowPathBlocking/SlowPathNonBlocking/FastPath) (https://sorbet.org/docs/lsp, https://sorbet.org/docs/server-status). LSP mode is limited to a single input directory/project, called out as "an artificial limitation" the team hoped to lift (https://sorbet.org/docs/lsp).

**2. Memory.** No documented ceiling/eviction; relies on an efficient `GlobalState` (symbols/strings in flat arrays via 32-bit `Ref` indices, not individually heap-allocated) for cache locality and low allocator traffic (https://blog.nelhage.com/post/why-sorbet-is-fast/). `--cache-dir` persists an on-disk cache so a full slow-path retypecheck can skip reindexing unchanged files.

**3. File watching.** Requires Watchman by default: "For the best experience, Sorbet requires Watchman… `--disable-watchman` means Sorbet will not detect when files have changed on disk due to things like changing the currently checked out branch" (https://sorbet.org/docs/lsp).

**4. Cancellation.** If edit B arrives while typechecking edit A, and A+B combined would still qualify for the fast path, Sorbet cancels the active typecheck and reprocesses A+B as one edit; updates are tracked as `{fastpath, slowpath, slowpath_canceled}`. The "Making Sorbet more incremental" post frames the motivation ("the base-case performance had slowed to a point where it was no longer fast enough to just do the work") and reports cutting full-retypecheck frequency "from 19% of edits when we started to only 10% of edits by the end" (https://blog.jez.io/making-sorbet-more-incremental/).

**Problems hit:** Watchman ignoring Sorbet's own ignore config — watching ~23,000 files Sorbet was told to ignore, exhausting inotify (https://github.com/sorbet/sorbet/issues/10678, apparently still open). Watchman refuses to watch a directory with no `.git`/`.hg`, surfacing an opaque error; workaround is `git init` (https://github.com/sorbet/sorbet/issues/7982). LSP crashes on hover (https://github.com/sorbet/sorbet/issues/1395) and on completion when type members/parameters combine (https://github.com/sorbet/sorbet/issues/681). Single-project-per-server limitation stated in the docs.

**Changes:** incremental-typechecking refinements cut slow-path frequency 19%→10% (blog.jez.io); `--cache-dir` added to cut slow-path cost. No evidence of moving off Watchman or adding a memory ceiling.

## Buck2 (Meta)

**1. Protocol.** CLI client → `buckd` daemon over gRPC; pipeline is evaluation → configuration → analysis → execution → materialization (https://buck2.build/docs/concepts/architecture/). Multiple daemons coexist via "isolation directories" — same isolation dir ⇒ shared daemon (https://buck2.build/docs/concepts/isolation_dir/). No public doc on version handshake or cancellation.

**2. Memory.** No documented policy; third parties wrap `buckd` in `systemd-run` cgroups to impose limits (https://github.com/ScorpiusDraconis83/buck2/pull/1103, a fork, not upstream).

**3. File watching.** Watchman-based, with a feature request for an inotify (`notify` crate) fallback (https://github.com/facebookincubator/buck2/issues/59); intent is "we watch for file notifications (with Watchman) and request both files and file-digests" for virtual/on-demand-fetch filesystems (https://buck2.build/docs/about/why/).

**4. Cancellation.** Not documented in sources found.

**Problems hit:** `buck2 kill` + rebuild triggers a full rebuild despite deferred materialization/cache flags (https://github.com/facebook/buck2/issues/547). Daemon loses track of previously built targets on restart in local mode — open feature request "Preserve local cache across daemon restarts" (https://github.com/facebook/buck2/issues/976). A third-party FUSE-mount wrapper reports stale file descriptors surviving a mount restart, requiring manual `buck2 kill` (https://github.com/firefly-engineering/turnkey/issues/19).

**Changes:** none confirmed shipped for the above in material gathered; issues read as open.

## Bazel server

**1. Protocol.** Long-lived server; client checks server version first — "if not, the server is stopped and a new one started" (https://bazel.build/run/client-server). One invocation at a time; concurrent invocations block or fail per `--block_for_lock` (same page).

**2. Memory.** Opt-in "memory-saving mode": `--discard_analysis_cache` (~10% savings, forces re-analysis), `--nokeep_state_after_build`, `--notrack_incremental_state` (https://bazel.build/versions/8.2.1/advanced/performance/memory, https://docs.bazel.build/versions/5.2.0/memory-saving-mode.html). `--experimental_oom_more_eagerly_threshold` exits after two full GCs above a heap threshold; `--shutdown_on_sys_mem` proactively shuts down on low system memory; `--max_idle_secs` (default 3h) idles the server out (https://bazel.build/run/client-server).

**3. File watching.** Not directly covered in fetched pages.

**4. Cancellation.** Ctrl-C forwarded as a cancellation request; a third rapid Ctrl-C SIGKILLs the server, **losing the entire in-memory analysis cache** (https://jmmv.dev/2020/09/bazel-test-streaming-bug.html; https://github.com/bazelbuild/bazel/issues/614 "Workers need to support cancellations"). Windows: subprocesses survive Ctrl-C (https://github.com/bazelbuild/bazel/issues/10573).

**Problems hit:** Build Event Service memory leak via retained protobuf buffers (https://github.com/bazelbuild/bazel/issues/21540); BEP message-size overflow on large builds (https://github.com/bazelbuild/bazel/issues/31328); persistent workers killed on test cancellation (https://groups.google.com/g/bazel-discuss/c/X_4Omrmz53w/m/ZaQ5Jj5_AgAJ); no-concurrent-invocation model is recurring friction for wrapper tooling (https://github.com/cockroachdb/cockroach/issues/80793).

**Changes:** Bazel 9.2.0 reportedly shipped BEP memory optimizations; "memory-saving mode" docs exist specifically as the response to analysis-cache memory pressure, trading re-analysis time for memory on every build.

## Gradle daemon

**1. Protocol.** Local socket; client sends args/project dir/env vars, daemon executes and streams output back (https://docs.gradle.org/current/userguide/gradle_daemon.html).

**2. Memory.** Default max heap ~512MB, configurable via `org.gradle.jvmargs`. Daemons self-expire after 3h idle, auto-stop under low system memory, and Gradle "monitors for memory leaks, automatically restarting daemons when exhausted heap space threatens performance" (same URL). No option to disable expiry-on-low-memory (open request: https://github.com/gradle/gradle/issues/24026); "Analyzing and understanding OOM errors is difficult" is an open meta-issue (https://github.com/gradle/gradle/issues/8261).

**3. File watching.** Gradle's VFS watches the filesystem to compute what needs rebuilding; on Linux, one inotify watch per watched directory, one inotify instance per daemon, with guidance to raise `fs.inotify.max_user_watches` for large builds (https://docs.gradle.org/current/userguide/file_system_watching.html). Disable via `--no-watch-fs`.

**4. Cancellation.** Not documented.

**Problems hit:** "Daemon disappeared" reports on 8GB machines traced to the OS OOM-killer, not a Gradle bug per se (https://www.needsomefun.net/fix-gradle-daemon-disappeared-8gb-ram/). GC thrashing under Gradle 6.0's conservative heap defaults in multi-module builds (https://www.javathinking.com/blog/daemon-is-stopping-immediately-jvm-garbage-collector-thrashing-and-after-running-out-of-jvm-memory/). Stale file-handle/lock on Windows: daemon holds jar/output locks until `gradle --stop` (https://github.com/gradle/gradle/issues/937, https://issues.gradle.org/browse/GRADLE-3315). Lock files at `registry.bin.lock`/`<pid>.out.log.lock` can get stuck and hang builds (https://www.javathinking.com/blog/gradle-build-is-hanging-without-failure-defaultfilelockmanager-acquiring-and-releasing-lock-on-daemon-addresses-registry/). Version/env skew: a new daemon spins up whenever Java version, JVM attrs, or Gradle version don't exactly match an existing one — explicit in docs — leaving many idle daemons accumulating (gradle_daemon.html). Antivirus scanning of `.gradle` caches slows builds (https://intellij-support.jetbrains.com/hc/en-us/articles/360006298560).

**Changes:** `gradle --stop`/`--status` added for manual cleanup; file-system watching (VFS) added with an opt-out flag; memory-leak auto-restart behavior added so daemons recycle rather than degrade silently.

## Kotlin compile daemon (kotlinc)

**1. Protocol.** Java RMI (per community sources; kotlinlang.org's own daemon page omits transport detail — https://kotlinlang.org/docs/kotlin-daemon.html); a registry file tracks ports/session tokens. RMI errors surface directly to users, e.g. "Error unmarshaling return header" (https://discuss.circleci.com/t/sporadic-exception-compilation-with-kotlin-compile-daemon-was-not-successful-java-rmi-unmarshalexception-error-unmarshaling-return-header-nested-exception/30131).

**2. Memory.** Separate process, isolated heap, inherits `-Xmx` from the launching JVM unless overridden (`kotlin.daemon.jvmargs=-Xmx1500m`).

**3. Lifecycle/versioning.** Configurable idle timeouts: `autoshutdownIdleSeconds` (2h), `autoshutdownUnusedSeconds` (1 min startup), `shutdownDelayMilliseconds` (1s after last client). Version incompatibility: build scripts on one embedded-Kotlin version create daemons for that version and can't create new ones for a different version without manual cleanup (community report).

**4. File watching/cancellation.** Not documented; a Gradle issue reports the Kotlin daemon "keeps disappearing with file-system watching enabled on macOS" — an interaction bug with Gradle's VFS watcher (https://github.com/gradle/gradle/issues/13382).

**Problems hit:** stale registry entries "trick Gradle into attempting connections to dead ports" (unverified, community); "Failed connecting to the daemon in 4 retries" (https://youtrack.jetbrains.com/projects/KT/issues/KT-75743); stale daemons in `LastSession` block builds (https://youtrack.jetbrains.com/projects/KT/issues/KT-81417); RMI "Connection refused" when the daemon process is gone.

**Changes:** no confirmed primary-source fix for stale-registry/version-mismatch; the configurable jvmargs and auto-shutdown timers are themselves the documented mitigation.

## Watchman

**1. Protocol (analog).** Single daemon reached over a Unix domain socket (named pipe on Windows); request/response PDUs either as newline-delimited JSON or BSER (compact JSON-superset binary framing) (https://facebook.github.io/watchman/docs/socket-interface). Subscriptions make the connection bidirectional (server pushes unsolicited PDUs). Watchman itself speaks neither LSP nor generic RPC — wrappers (Jest, Buck, Mercurial) translate, matching beni's "private binary + separate translator" option.

**2. Memory.** No hard ceiling historically; reports of idling >1GB, climbing to 2–3GB+swap over long sessions, attributed to an "append-only cache [that] grows unbounded" (https://github.com/facebook/watchman/issues/593, 415, 324). Config knobs, not an architecture change, were the answer: `gc_age_seconds` (12h default) ages out change history; `idle_reap_age_seconds` (5 days default) cancels unused watches and releases OS resources (https://facebook.github.io/watchman/docs/config.html). A fork, **watchwoman**, exists specifically as a "drop-in Watchman replacement that doesn't eat your RAM," wire-compatible with Jest/Metro/Sapling (https://github.com/radiosilence/watchwoman).

**3. File watching.** Abstracts inotify/kqueue/FSEvents/portfs/ReadDirectoryChangesW. Founder wezfurlong, on the original 2013 HN launch thread: at Facebook's scale, hashing every file was too slow and a static dependency graph was infeasible to maintain, so a persistent watcher daemon was the only option, written in C "for tight and deliberate control of resources" (https://news.ycombinator.com/item?id=5795146, comment 5795835). inotify watch exhaustion (default 8192) is a classic complaint, producing a non-recoverable error without a root-level sysctl change (https://github.com/facebook/watchman/issues/132, 163). FSEvents on macOS never pairs renames (one "renamed" flag, no cookie), so every atomic save (temp-file+rename), `mv`, or `git checkout` forces a full-tree **recrawl** (https://facebook.github.io/watchman/docs/troubleshooting.html; background: https://danielcosenza.com/posts/mac-fsevents/). `settle` (ms) delays firing subscriptions after the last event; 3.2+ also holds notifications open across an in-progress VCS operation to avoid firing on a half-updated tree (https://facebook.github.io/watchman/docs/cmd/subscribe.html).

**4. State/crash recovery.** `state-enter`/`state-leave` mark a watch as "mid-rebase" etc.; if the entering client disconnects without leaving, Watchman auto-clears the state so subscribers don't wedge (https://facebook.github.io/watchman/docs/cmd/state-enter). Triggers persist to disk and roots re-establish after restart, but a crashed daemon still needs external respawn, and subscribers reportedly drop silently in the interim (per watchwoman's README framing).

**Changes:** `gc_age_seconds`/`idle_reap_age_seconds` config knobs for memory; the watchwoman fork as a more radical answer the core project didn't take itself.

## Zig build-server / incremental compilation

**1. Protocol.** `zig build --listen=-` turns the build runner's stdin/stdout into a length-prefixed binary "build server protocol," distinct from and lower-level than LSP. The protocol carries an explicit version integer that increments on breaking changes specifically because third-party tools (not just Zig-internal callers) depend on it (https://codeberg.org/ziglang/zig/issues/35538). Server→client messages cover build status, errors, resource metrics, generated-file changes, config updates; client→server is limited to build commands. A noted rough edge: a tool must discover available build steps/options by parsing `build.zig` separately. **ZLS** (community LSP) implements beni's exact "binary protocol + separate translator" pattern: it shells out to `zig build check --watch` and translates error bundles from the build-server protocol into LSP diagnostics (https://zigtools.org/zls/guides/build-on-save/, https://kristoff.it/blog/improving-your-zls-experience/).

**2/3. Memory & watching.** `zig build --watch` (https://github.com/ziglang/zig/pull/20580) does its own filesystem watching, combinable with `-fincremental`. Known gaps: doesn't pick up sub-compilation inputs (compiler_rt, glibc, musl sources) or re-run on `build.zig` changes itself; doesn't reclaim `.zig-cache`, which grows unbounded under repeated watch rebuilds (https://github.com/ziglang/zig/issues/20929). Platform breakage: fails to trigger on macOS 14.5 from VSCode saves (https://github.com/ziglang/zig/issues/21905); "reached unreachable" crashes under WSL/Linux 5.15 (https://github.com/ziglang/zig/issues/23116, 23128); Windows "failed to rename compilation results" under `--watch` (https://github.com/ziglang/zig/issues/21104); regression on platforms without a watch backend (https://github.com/ziglang/zig/issues/24682).

**4. Cancellation/correctness.** Maintainers are explicit incremental mode is not stable: "incremental compilation makes you more likely to encounter compiler bugs, including false positive compile errors, false negative compile errors, miscompilations… it's definitely possible to crash the compiler right now" (https://mlugg.co.uk/posts/incremental-compilation-internals/). Only the self-hosted x86_64/ELF and C backends have solid incremental support; others are "almost certain to crash or miscompile." Documented stale-state bugs: error-bundle corruption making a stale error persist forever across updates; crashes sorting analysis errors referencing source locations deleted in a later update (fix: https://github.com/ziglang/zig/pull/22379, tracking https://github.com/ziglang/zig/issues/22696). A known perf floor: the graph-traversal step at flush costs ~30ms even with zero changes (same blog post).

## dune RPC + merlin (OCaml)

**1. Protocol/versioning.** Dune's RPC (`dune-rpc`, labeled "experimental") negotiates version **per method**: client/server exchange supported versions for each individual procedure at session start and settle on a version menu, checked via `prepare_request` before send (https://ocaml.org/p/dune-rpc/3.24.2, https://ocaml.org/p/dune-rpc/3.15.3/doc/...). Classic Merlin does not speak dune-rpc/LSP directly — `dune ocaml-merlin` runs a dedicated "merlin configuration server" explicitly not meant for general consumption, queried only by the Merlin editor backend (https://www.mankier.com/1/dune-merlin). Newer ocaml-lsp versions reportedly query the running dune instance over dune-rpc directly instead (secondhand, not pinned to one source).

**Problems hit:** stale diagnostics because watch builds don't see unsaved editor buffers (secondhand synthesis); duplicate diagnostics from overlapping eager-RPC and watch-mode builds, fixed in https://github.com/ocaml/dune/pull/16491 (companion: https://github.com/ocaml/dune/pull/16490). Recurring config/version-skew error: "The current Merlin configuration has been generated by another, incompatible, version of Dune. Please rebuild the project" (https://github.com/ocaml/merlin/issues/1591; Windows recurrence after 3.6.2: https://github.com/ocaml/dune/issues/7753). Stuck RPC state: "connection to persistent client stuck indefinitely" (https://github.com/ocaml/dune/issues/4658); stale sockets in `_build/rpc/clients/` cause hangs/ECONNREFUSED (around https://github.com/ocaml/dune/pull/15700). Concurrent RPC builds were only added later (https://github.com/ocaml/dune/pull/11712 "Allow concurrent build with RPC server"), implying earlier dune-rpc could not supersede an in-flight build with a newer request — no cooperative-cancellation design found. Cold-start indexing is "generated the last time you built" and "costly especially from a cold build" (https://discuss.ocaml.org/t/my-lsp-server-stopped-working-after-upgrading-dune-need-help-with-better-solution/16924).

**Changes:** per-method RPC versioning as the answer to client/daemon skew; concurrent-RPC-build support added later; diagnostics-dedup fix via dune#16491.

## ghcide / Haskell Language Server (HLS)

**1. Protocol.** Standard LSP/JSON-RPC via the `lsp` Hackage package, with VFS buffer overlays; no private wire format. Built on **Shake** as the incremental engine (dependency graph of build "rules" keyed by file+query) (https://hackage.haskell.org/package/lsp, https://mpickering.github.io/ide/posts/2020-06-12-performance-of-ghcide-020.html).

**2. Memory.** User report: 8GB RAM / 400% CPU on a large project, every IDE command timing out (https://github.com/haskell/haskell-language-server/issues/1036). Maintainer Neil Mitchell's diagnosis: versions 0.0.5–0.1.0 had a near-constant space leak because Shake's in-memory cache (unlike disk-backed Shake) was never forced (http://neilmitchell.blogspot.com/2020/05/fixing-space-leaks-in-ghcide.html). Fix in 0.2.0: reuse GHC's own `.hi`/`.hie` interface files instead of holding everything live, cutting memory to "nearly zero leaked bytes." A later regression: `rawDependencyInformation` using `FilePath = String` causes GC pressure on big projects (https://github.com/haskell/haskell-language-server/issues/4598).

**3. File watching / version skew / multi-client.** "Cradles" (hie-bios) resolve project GHC info; mismatch between the GHC that built HLS and the project's GHC produces "GHC ABIs don't match!" (https://github.com/haskell/haskell-language-server/issues/351, 2495; https://github.com/NixOS/nixpkgs/issues/321569). Multiple HLS processes can accumulate without all shutting down on client request (https://github.com/haskell/haskell-language-server/issues/499). Concurrent use across projects causes hie-bios to grab the wrong cradle (https://github.com/haskell/haskell-language-server/issues/4164). Moving the workspace root tells the new server about only the one triggering document — other open editors' documents are silently orphaned (https://github.com/haskell/haskell-language-server/discussions/4048). A separate tool, `lspd`, exists purely to multiplex several editor clients onto one server process per (root, server) pair — implying HLS itself handles multi-client poorly.

**Changes:** 0.2.0's interface-file reuse fix for the space leak; no confirmed fix found for multi-client/workspace-move orphaning (lspd is a third-party workaround, not a core fix).

## Roc language server

**1. Protocol.** stdio only — "the default and only transport" (Richard Lepert, https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/editors/near/605739542).

**Problems hit** (contributor review thread by Lukas Juhrich, https://roc.zulipchat.com/#narrow/channel/316715-contributing/topic/lsp.3A.20suggested.20improvements.2Frefactors/near/614090759): single-threaded blocking loop — a full `buildResolvingMain` runs synchronously inside `didOpen`/`didChange` before the next message is read, so `shutdown` can time out in Helix even though shutdown itself is cheap. Memory leak: server advertises `openClose: true` but has no handler, so closing a tab never clears the doc store or clears diagnostics; a contributor's fix still did not visibly reduce memory in manual testing, called "crude but sufficient" (https://roc.zulipchat.com/#narrow/channel/316715-contributing/topic/lsp.3A.20suggested.20improvements.2Frefactors/near/621332448). Failing handlers only log, so clients hang on that request id until timeout. Hover/goto-def map every error to `null`, conflating "checker crashed" with "nothing here." `didChange` correctly converts UTF-16 offsets but hover/goto/completion still treat `character` as a byte offset. Cooperative cancellation is an acknowledged future gap ("full coop-cancel is a later step"). Crashes: Zed-on-Windows panic on almost any edit (https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Windows.20zed.20language.20server.20crash/near/625040506); `[ROC CRASHED] Invalid entry_idx` reported separately (https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/How2Platform/near/582460733).

**Watch mode.** Roc's CLI deliberately has no `--watch` flag: Richard Feldman — "if the platform specifies that it supports 'watch mode' then it's just automatically activated" (https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Roc.20cli.20workflow/near/451025611); pushback (Anton) that an unwitting user could run a watched dev server in production (same thread, near/451030466).

**Changes:** completion support landed via a self-described "largely vibe coded" PR #9071; UTF-16 handling partially fixed afterward by another contributor.

## Gleam

**1. Protocol.** `gleam lsp`, standard LSP/JSON-RPC; "compiles your Gleam projects every time you hit save" (https://gleam.run/news/v0.21-introducing-the-gleam-language-server/).

**2. Memory/incrementality.** No long-lived checked-state daemon; per-module on-disk caches (`.beam`/`.hrl` plus a `bincode`-serialized `.cache` of interfaces/types) read back each invocation (https://gleam.run/news/v0.26-incremental-compilation-and-deno/). A correctness bug close to beni's determinism concern: cold builds of unchanged packages produced nondeterministic cache bytes (https://github.com/gleam-lang/gleam/issues/6383), addressed by https://github.com/gleam-lang/gleam/pull/4325.

**3. File watching.** No native watch mode in the build tool; `gleam build --watch` is a long-open feature request explicitly inspired by Elm Reactor, discussing building on esbuild's dev server or a custom loop (https://github.com/gleam-lang/gleam/issues/2570) — currently relies entirely on editor save-triggered recompiles.

## esbuild serve/watch

No daemon/editor protocol — a library/CLI `context` API (`rebuild()`/`watch()`/`serve()` as methods); shared immutable ASTs reused across incremental rebuilds (https://esbuild.github.io/api/). Issue #2576: a user needed file-change notifications decoupled from the triggered rebuild to avoid duplicate overlapping rebuilds in an Electron app (https://github.com/evanw/esbuild/issues/2576); fixed by rewriting the incremental API around an explicit context object (PR #2816, https://github.com/evanw/esbuild/pull/2816). Cancellation-equivalent: calling `rebuild()` while one is in flight **merges** into it rather than starting a second; serve mode triggers a rebuild per request only if none is running, then waits — "esbuild never serves stale build results" (https://esbuild.github.io/api/, https://hachyderm.io/@evanw/109685897217728374).

## Vite dev server / Turbopack (Next.js)

**File watching.** Vite wraps `chokidar` (inotify/FSEvents/polling); directories can be counted multiple times against `fs.inotify.max_user_watches` (~8,192–10,000 default), producing the chronic Linux `ENOSPC: System limit for number of file watchers reached` (https://vite.dev/guide/troubleshooting, https://dev.to/iyadchafroud/error-from-chokidar-system-limit-for-number-of-file-watchers-50hj). A reported variant: another daemon on the host consuming ~496k of a 500k watch budget starves `vite dev` (https://github.com/intent-hq/intent/issues/5026). An uncaught watcher 'error' event (e.g. Windows `EBUSY`) crashes the entire dev server process — open issue (https://github.com/vitejs/vite/issues/23470).

**Turbopack memory.** Next.js 16.2.9 report: unbounded RAM growth on a 496-file/63-route project — RSS 434MB→16GB over a session, +250MB/10s idle, 17–25% idle CPU, `.next/dev/cache/turbopack` growing to 6.5GB unpruned; three suspected causes layered: an unpruned persistent cache, a watcher feedback loop (Turbopack's own writes into `.next/dev` retrigger its watcher), and repeated Fast Refresh invalidation (https://github.com/vercel/next.js/issues/94915; auto-closed for a broken repro link, reporter cites PR #94735, watcher path filtering, as partial mitigation).

**Changes:** Next.js 16.1 added filesystem persistence for Turbopack's cache; 16.3 added **eviction from memory** — inactive routes move to disk and reclaim when idle, reported to cut dev-server memory up to 90% on large apps (https://nextjs.org/blog/next-16-3-turbopack).

---

## Cross-project table

| Project | Protocol | Memory policy | Watching | Cancellation |
|---|---|---|---|---|
| rust-analyzer | LSP/JSON-RPC, stateless-per-request + VFS | No ceiling; salsa opt-in per-query LRU; durability tiers | Editor/LSP events + VFS | Revision counter → panic → `Result<_, Cancelled>` |
| gopls | JSON-RPC/LSP, forwarder-to-shared-daemon (TCP/Unix socket) | No eviction; "restart to fix" | Client-driven default; `fsnotify`/`poll` opt-in | Not found |
| tsserver | Custom JSON-over-stdio (not JSON-RPC) | User-set cap only, no eviction | Server's own per-dir fs.watch/polling | Named-pipe cooperative, per-request pipe names |
| Sorbet | LSP/JSON-RPC + extensions | No ceiling; efficient `GlobalState`; disk cache | Requires Watchman (degrades without) | Fast/slow-path cancel-and-merge on new edit |
| Buck2 | gRPC to `buckd` | Undocumented; third-party cgroups | Watchman (+ requested inotify fallback) | Undocumented |
| Bazel | Version-checked client/server, gRPC-ish | Opt-in discard-cache / idle / sys-mem flags | Not found in docs fetched | SIGINT cooperative; 3rd Ctrl-C = SIGKILL, loses cache |
| Gradle daemon | Local socket | ~512MB default heap; auto-restart on leak; idle expiry | VFS watcher (inotify-based), opt-out | Not documented |
| Kotlin daemon | Java RMI | Inherits/overridable `-Xmx`; idle timeouts | Not documented (interacts badly with Gradle VFS) | Not documented |
| Watchman | Unix socket, JSON or BSER binary | No ceiling; `gc_age_seconds`/`idle_reap_age_seconds` | Is the watcher (inotify/FSEvents/kqueue/etc.) | `state-enter`/`state-leave`, auto-clear on disconnect |
| Zig build server | `--listen=-`, versioned binary framing | N/A (compiler process) | `--watch`, own FS watcher | Explicit protocol version; incremental mode "not stable" |
| dune RPC/merlin | Per-method versioned RPC; merlin via separate config server | Not documented | Editor/dune watch build | Concurrent RPC builds added later; no cooperative-cancel found |
| ghcide/HLS | LSP/JSON-RPC + VFS, Shake engine | Historical space leak, fixed via `.hi`/`.hie` reuse | Editor events + cradle resolution | Not documented |
| Roc LSP | stdio only | Leak via missing `didClose` handler | No `--watch`; platform-declared "watch mode" | Explicitly not yet built ("later step") |
| Gleam | LSP/JSON-RPC | Per-module on-disk cache, no daemon | No native watch; save-triggered only | N/A |
| esbuild | In-process context API, no wire protocol | N/A (process-local) | chokidar-class watching, decoupled from rebuild via context API | In-flight rebuild merges new requests instead of duplicating |
| Vite / Turbopack | Dev server, HMR | Turbopack: unbounded until 16.1/16.3 added persistence+eviction | chokidar/fs.watch; inotify-limited | Not documented |

## Recurring problems, by project reporting them

- **Memory growth to the point of OOM or required restart**: rust-analyzer, tsserver, Watchman, ghcide/HLS (historical), Gradle daemon, Bazel (BES leak), Turbopack, Roc LSP (missing didClose leak), Sorbet (mitigated architecturally rather than reported as a problem).
- **inotify `max_user_watches` exhaustion**: tsserver, Watchman, Gradle, Vite/chokidar, Sorbet (via Watchman misconfiguration).
- **FSEvents / atomic-save-rename defeats a watcher, forcing a full recrawl**: Watchman (macOS).
- **Client/daemon or tool/config version skew causing wrong or broken behavior**: gopls (env/socket mismatch), tsserver (bundled vs. workspace TS version), Gradle (new daemon per Java/Gradle-version combo), Kotlin daemon (per-version daemon isolation), dune/merlin ("incompatible version of Dune, please rebuild").
- **Stale sockets / lock files / orphaned daemon processes**: gopls (`$TMPDIR`-dependent socket path), Gradle (`registry.bin.lock`, stuck locks), Kotlin daemon (stale registry entries), dune (stuck RPC client connections), Buck2 (stale state after restart), Watchman (crash requires external respawn).
- **Daemon doesn't survive or doesn't correctly recover its own restart**: Buck2 (loses target tracking), Watchman (crash recovery gap), ghcide/HLS (workspace-root move orphans other open docs), Zig incremental (stale-error persistence across updates).
- **Cancellation either absent, incomplete, or destructive**: Bazel (SIGKILL loses the whole cache), Roc LSP (not yet built), dune (no cooperative cancel found; concurrent RPC builds only added later), Buck2 (undocumented).
- **Multiple editor clients / multiple projects sharing one daemon badly**: ghcide/HLS (wrong-cradle grabs, needed a third-party multiplexer `lspd`), gopls (redundant daemons from inconsistent `$TMPDIR`).
- **Watcher and build/cache system interacting adversely (feedback loops)**: Turbopack (own cache writes retrigger its watcher), Kotlin daemon (disappears under Gradle's VFS watcher on macOS).
- **Platform-specific (Windows/macOS) daemon or watch failures**: Zig (Windows rename failure, WSL/Linux-5.15 crashes, macOS 14.5 trigger failure), Bazel (Windows subprocesses survive Ctrl-C), Vite (Windows `EBUSY` crashes the dev server), Roc LSP (Windows/Zed panic), Gradle (Windows file-lock holding).
