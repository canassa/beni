## 2026-10-21 21:56 CEST — qualify master with the held inline work

**Working state before qualification**

The held browser-inline parent is `24bdda22d9581d4093096fc98053a21807322b46`,
with #619, #628 and #630 integrated. It has not landed on master. This session
merges master `3fafb445ce63217dfd1894a14f31e24687e87c98` into that parent for
#295. The automatic merge has no conflicts. It brings the arena/column growth
and scratch-retention changes, the computed-property prototype correctness fix,
server transcript updates and the Marko reference notes. The only CLAUDE.md
change records that core Log has landed. No new feature is being added here.

The exact whole-model-write feature (#638, draft PR #641) stays frozen separately
at `9b0ca69558cd6e040f362d36b29f4752495db236`. Its reference hashes, gates and
pending checks passed; all 30 compared HTML/JavaScript pairs were identical for
programs without whole writes. Its compilation-cost bar failed: big-component
N=64 measured +0.885% CPU and +1.07% wall over four balanced pairs; all three
N=256 CPU pairs were about one second slower. The 40 raw measurements and their
provenance are linked from [the original packet](https://github.com/canassa/beni/issues/638#issuecomment-6324688889)
and [the repeated cost packet](https://github.com/canassa/beni/issues/638#issuecomment-6325150037).
The old candidate's LLVM qualification is running before this session's shared
suite lock. These historical results remain intact. Master must be identical
on both sides of the next matched measurement; moving only the candidate would
not clear the failed bar.

The general declaration-totality work (#618) has stable results for its 12 graph,
2 formatting, 23 digest and 29 core hashes. Against the old parent its normal
core test still costs 4,301M instructions against the 4,300M budget. There is no
budget exception or grant. Its separate 18-file patch will be ported to this
qualified control before further comparison.

The actual compiler prototype for #640, third canonical variant, measures
920 raw / 558 gzip / 483 brotli bytes against the manual variant's 925 / 559 /
484. This corrects the earlier optimistic probe. General captures and dispatch
qualification remain owed. Cursor investigation #642 reproduces in Chrome on
all three platforms and in happy-dom; it is queued, not in progress, and no fix
or source change is authorized.

All owner design decisions above have approval; there is no pending technical
parameter question. The Lean work remains paused. The frozen S1 size bars are
unchanged. The last isolated handler cut measured unique-components at
2,749.085 + 256.731 B/widget (validation 644.187 + 19.349), and big-component at
2,055.230 + 91.081 (validation 422.683 + 9.716), with `--lists none`. Its fixed
cost increases and small-app regression remain part of that measurement.

**Next action**

Audit the merge, then run the full reference hash recorder, gates and pending
checks in order under `/tmp/beni-codex-gates.lock`, after the running LLVM batch.
Inspect every additional hash or golden movement rather than blessing it. This
worktree has its own local cache; no additional LLVM or ReleaseFast build is
planned here. Commit only a green tree. The manager will publish the resulting
control and diary. A later whole-write candidate must contain only that feature's
delta and promised review comments on this same new base, with fresh matched
cost qualification.
