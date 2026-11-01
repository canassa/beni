## 2026-10-31 23:52 CET — Separate selected-entry emission state

**What I did**

Specified workers-selected-emission.md before the compiler change and linked it
from workers-emission.md. On accepted 07cd plus frozen C baseline tree
3e7ab2a20bf9c2591b4bbcbaa4906d4e8cc650df, split Emit's immutable options and
post-validation selected entry/runtime-plan inputs from 45 mutable projection
fields. Contract-only runtime/diagnostic scratch stays separate. Session interner,
profile and existing artifact/cache services remain explicitly mutable; this is
not a concurrent-entry service protocol. All original pass/root calls stay in
order, including initializer effects, lifted/deferred roots and runtime refinement.

Centralized projection cleanup on every run/check/inspection exit and made the
three Result slice transfers transactional. Both success and nothingWritten keep
the baseline transfer semantics; if a later transfer fails, earlier transferred
messages/text are released. No cache/serialization ABI, runtime, own2, source
acceptance rule, public worker API, output layout or JavaScript changed.

Debug baseline SHA256:
2ff70cf8b5921011c8fd72e14884f4fd142a17f38b842a913afb002e57f680ca.
Frozen candidate Debug3 SHA256:
e970bc6ca23ab8a8d1d48807aa49ed81b35d0b8219614d91916144f7f5976911.
Author evidence remains under workers-entry-emission/scratch on Dagon.

Validation completed before this freeze:

- Two new resident --watch semantic tests passed, then all 15 registered devloop
  cases passed with zero skip/failure/leak/logged error. A type-clean emitter
  record-preflight refusal occurs after pending output generation; it preserves
  the entire previous tree. Repair in the same Session matches a fresh jobs=1
  tree and executes the expected initializer/deferred callback result. Separate
  development/release cases cover both layouts and source maps.
- Two named Result ownership/transfer tests passed through the normal filtered
  hermetic graph (88 steps, 11 total harness/import/semantic checks; only two
  new semantic tests). Forced remap refusal exercises real allocation fallback
  failure at each of the three transfers and verifies all allocated bytes freed;
  success/refusal retain their correct diagnostics/text/counters.
- 112 baseline/candidate builds compared complete output paths and SHA256 bytes:
  seven real source cases, development/release, each compiler jobs 1,8,1,8.
  Suspendable twin/layered platform, schema validators, Debug context, generic
  runtime table, browser markup, browser-inline lifted pieces and library all
  matched, including source maps and manifest. No golden was blessed.
- The existing entire corpus:emit walker passed (one registered walker, zero
  skips/failures/leaks/logged errors), covering its development/release goldens.
  This is not a claim that the full gates ran in the author lane.
- Recorded the two new program-run hashes from actual successful Node runs.

**What I learned**

The first candidate compile found one missed nested helper receiver (em.options);
its log is retained, then the corrected build passed. The byte-matrix setup
initially omitted a fixture's custom platform and later supplied a single file
instead of its directory source root; both baseline-only setup failures and
commands are retained. Corrected execution resumed without rerunning the already
green families. There was no production or golden mismatch in these probes.

Partial Result transfers can leak already-published ownership on allocation
failure even when ordinary successful builds are byte-identical. The explicit
transfer owner fixes that lifecycle boundary without changing emitted output.

This is single-selected-entry state isolation only. Partial entry discovery is
still not executable authority; C/EntryHost/Wire/ownership/public launch are not
certified by this work. Manager independent review, exact-tree full gates and
any required scope-appropriate costs remain pending. Nothing is committed or
pushed by the author.
