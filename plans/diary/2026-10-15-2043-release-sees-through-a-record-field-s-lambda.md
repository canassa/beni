## 2026-10-15 20:43 CEST — release sees through a record field's lambda

**What I did.** Issue #95 (queue row 81). Since `init` is a function of `⊤`, `--release` kept `init:()=>…`, its key and the call `a.init()` on every `browser-tea` page that writes `init` as a lambda in the record. On master the gap was still there. Two rules, both in `Spec`, specified first as a dated amendment of §9's slice 8:

- `effectFree` knows a call of functions that only make a value (`pureCall`, `makesOnly`): a safe callee chain, fact 3 says only program functions, each body empty or `return <inert>`, and every argument effect-free. The unread `app.init ⊤` and `Navigation.key ⊤` arguments go, then the key and the lambda.
- Slice 8 skips its size model at a call through a property when that call is the function's only use in the program (`soleCalls`), and accepts inert extra arguments there (`app.init(null)` of a lambda with no parameter for `⊤`). `element` gets its model back as a literal.

Measured against `7bbcb6603`: `element` 1 132 → 1 102, `navigation` 3 978 → 3 945 release brotli; `bench/size.mjs` 13 smaller and none larger; the `browser/` corpus 267 smaller, 6 larger by 2–23 brotli bytes, each with fewer raw bytes; Conduit +6 on `browser-tea`. Cesar accepted those increases on the dashboard (`release-purity-q1`). Fixtures `emit/release/app/SpecRecordLambda` and `run/SpecializeRecordLambda`; three release goldens moved; run hashes re-recorded. Rebased three times while measuring (PR #150 and the compiled schemas landed in between). The review's one real point (uses inside bodies copied in the same pass) is fixed.

**What I learned.**

- The issue's "purity fact" was only half of it. On `element` the model is an object that the first state reads, so dropping an unread call does nothing there. Slice 8's size model priced the body against the call alone, and a record's lambda never fits that. Counting the function's uses is what makes the inline pay.
- `releaseKeeps` asking the same test changed nothing unless the facts ran again. Running them again cost Conduit's `browser-tea` build 6.6 % more instructions for zero bytes, so I took it out and filed #167.
- A `perf stat` of the safe compiler on Conduit found that cost in minutes; the `--self-profile` counters (`spec_analyses` 9 → 10) showed where it came from.
- The extra-argument rule first applied to every call. On the newest master that made Conduit +39 / +26 brotli (fewer raw bytes) and `Routes` +24; kept to calls through a property, Conduit is +6 and +0. A rule's reach is worth measuring on the real app, not only on the corpus, and again after each rebase.
- Removing one declaration moves every later short name. Brotli then sometimes grows by up to 31 bytes at fewer raw bytes. No variant of this fix had zero increases.
- `pkill -f` with a pattern that is also in the shell's own command line kills that shell.
