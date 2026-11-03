## 2026-11-03 07:24 CET — Follow replies through Cells and Opts

**What I did**

Rebased the reply compiler onto the rewritten workers-hostfree history with
`--onto origin/workers-hostfree 195586a26a`, retaining the shared caller fence
and the restored three-argument private-token view constructor. Known and
generic Cell/Opt messages now use the same conservative reachability as Ref.
Known optional plans skip the private absence identity before their payload.
Added a happy-dom Wire view/trie fixture alongside the native-worker Chrome
fixture. Reverting normalization throws DataCloneError in happy-dom.

An expanded Reply-free argument exposed ordered record temporaries losing an
effectful call in release after all reads disappear. Marked those temporaries
with the original expression's effect, as other source-derived bindings do.
The ordinary no-worker RecordArgumentEffects fixture reproduces the wrong
answer before the fix. All seven reply tests, both new gate fixtures, pins,
pack rebuild and Chrome checks pass on the final base. Run hashes and final
gates were run under the shared lock; inherited oracle failures were retained.

**What I learned**

Cell is its record and Opt is its payload or the private absence sentinel;
classifying either as a foreign leaf disagrees with generic traversal. A
known optional list especially needs the absence guard. Scan-only artifacts
must also survive caching when they have no ordinary type keys. The existing
cache fixture caught an omitted retention condition during conflict resolution;
it was restored. Issues #1763 and #1764 remain separate owner work.

Final base: 2a3718f82f (workers b688a8ffd2). Re-recorded eight reply and two
happy-dom records; the ordinary run refresh retains nine inherited failed
oracles. The final unfiltered gates ran once: 253/284 steps succeeded,
2118/2179 tests passed, 16 skipped, 45 inherited failures. No new owned test
failed. The native Worker Chrome integration and library/skill-api rebuild
are green. Evidence is under worktree-evidence/wd-size/reply-scan.
