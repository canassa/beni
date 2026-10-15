# Browser platform decision batch

Research 100; see PROTOCOL.md for the sample plan fixed before timing.

The measurement host is azathoth, its main checkout pulled to master
6c327a9f17050941bc170f9e888160795ca471f5. Only measurement harness files are
changed. Compiler, core, platform and app sources stay at that revision.

Inside `nix develop .#browser`, with Zorg in `~/.local/bin`:

```sh
zorg build -Doptimize=ReleaseFast
cp zig-out/bin/beni zig-out/beni-s8-frozen
bash bench/s8/prepare.sh
BENI="$PWD/zig-out/beni-s8-frozen" node bench/s8/build-apps.mjs
BENI="$PWD/zig-out/beni-s8-frozen" node bench/conduit/measure.mjs > bench/s8/results/conduit-counts.json
bash bench/s8/time.sh
bash bench/s8/post.sh
node bench/s8/summarise.mjs
```

Run measurement commands serially on an idle host. `chrome.sh` pins Chrome
and descendants to 2–5,8–11; `time.sh` pins Node harnesses to 0–1,6–7.
`S8_CHROME` names the actual Chrome executable. The official JFB wrapper uses
single-framework invocations to enforce candidate order because upstream
ignores argument order and uses the server's `/ls` enumeration. The four clean rounds rotate candidates at each operation and retain native
reports; a pooled native report retains every observation. The earlier contaminated epoch is retained under invalid-build-race
and excluded from every summary. No automatic selective retry is enabled.
The sweep/table harnesses also accept `--no-retry` for this campaign.

`results/app-builds.json` records every build command, status, diagnostic,
source hash, binding provenance and byte account. `.mjs.gz` and `.map.gz`
store lossless source/map snapshots; their gzip envelopes are archival, not
the measured delivery compression. Ordered core/runtime removals plus the
app/startup remainder sum to the whole brotli result. Compression context and
order affect these charges; they are not causal or independent downloads.
The normalized table part files use the contract's existing `size-parts.mjs`
protocol, separately from the as-emitted application byte tables.

`results/tables.md` and `summary.json` are regenerated from raw observations
by `summarise.mjs`. Every click remains; stream windows and clustered sweep
clicks are explicitly distinct from fresh-page sample counts. Official short
throttled script medians are descriptive, never used to judge speed parity.

`machine.txt` retains the initial hardware/governor listing. The compiler's
version command overwrote the beginning of that redirected stream; the
separate buffered `provenance.json` records the complete commit, versions,
SHA-256s, topology and governor without sharing an output file descriptor.

The completed campaign retained 1,080 table samples, 10,188 sweep observations,
600 criterion-6 Todo pages, 240 Conduit pages and 200 full-app pages, plus four
native JFB rounds. `audit.json` checks completeness, finite values, no retries,
balanced Conduit order and the independently built executable hashes.
`summary.json` names observation counts `samples`; Todo's `n` is its scenario
size, not its count.

The first full-app setup awaited a virtual animation frame before installing
the stopwatch. `apps-setup-stall.json` records that live state; its raw capture
with the Nix hook prefix is kept separately. The corrected whole app grid
started with zero retained observations. No earlier phase was repeated.

Linux gates exit zero. Native Chrome exits one: Sternhalma's 4,988-line
expected/actual transcript differs only in six-significant-digit CSS pixel
serialization under the stated narrow normalization, consistent with an
oracle mismatch. A separate full tea-only golden replay was not run. `chrome-sternhalma-diagnosis.json` records the comparison method
and hashes, while `chrome-tests.log` remains the unedited failure. No golden was
blessed. The full V3 campaigns remain owed.

`post.sh` stops on that red native check. This run resumed only its unfinished
source-diff and provenance steps, recorded in `provenance-continuation.log`.
Within the environment established by `post.sh`, those steps are:

```sh
export BENI="$PWD/zig-out/beni-s8-frozen"
export S8_CHROME="$(command -v chromium)"
git diff --exit-code 6c327a9f17050941bc170f9e888160795ca471f5 -- src core platforms examples > bench/s8/results/production-source-diff.txt
node bench/s8/provenance.mjs
```

The older `todo-sizes.json` omits brotli's input-size hint.
`todo-release-bytes.json` consistently reprices and archives the exact five
timed Todo files with the hint, checking their hashes against timing metadata.


Review adds read-only diagnostics on the same retained observations:

    node bench/s8/audit.mjs --review
    node bench/s8/review-analysis.mjs

review-audit.json checks per-page sample membership, the actual JFB command
log order, chronological table/Todo/app order and both Conduit modes.
review-analysis.json retains all nine endpoints by page and separates the
default census from supplemental apps. Sweep rotation uses only two positions,
repeated for every cell; it is not a balanced design across all five/six available positions.
The original manifest describes the measurement/report commit, while review
validation separately hashes the updated analysis scripts.

The review changed analysis code, so the full Linux gate was run again and
passed; review-validation.json records its 39.59-second run and the two analysis
script hashes. Native Chrome and the comparisons were not repeated.
Commit 95d875e7b preserves the original measurement/report files corresponding
to source-manifest.json; subsequent changes are read-only analysis and docs.


The committed audit.json is the original count/hash audit from commit
95d875e7b and predates the new order assertions. The committed review-audit.json
was produced by node bench/s8/audit.mjs --review. The current script executes
all assertions with either invocation; the flag changes only the destination.
Use --review to reproduce the enhanced checks without overwriting the
historical audit.json.

measurementEvidenceCommit in review-analysis.mjs deliberately names the
immutable original evidence commit, 95d875e7b. Recording the current checkout
instead would identify a later analysis revision. The script's self-hash and
review-validation.json identify the analysis code separately.
