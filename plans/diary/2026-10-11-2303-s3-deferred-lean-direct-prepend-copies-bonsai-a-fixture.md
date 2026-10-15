## 2026-10-11 23:03 CEST — S3 deferred, lean direct, prepend copies, Bonsai, a fixture split

**What I did.** Finished S3 (PR #48): kill criterion 5 and the P3 criterion fired (4 524 B vs
2 830 B; swap 2.13×). A leave-one-out size investigation showed the per-message code is ≈ 200 B,
less than vanilla's DOM code; the miss was the persistent `List` (741 B), a general reconciler as
universal fallback (715 B), per-shape scripts and a key map, mount, and markup vanilla keeps in
its HTML. The owner deferred the verdict. A hand-written lean direct (plain arrays, exact edits,
P3-sized reconcile, minimal mount) measured 1 764 B with markup in the HTML, at vanilla parity or
better on every operation but swap, whose samples are bimodal for every subject (report 70 §7,
PR #51). Landed the prepend decision (PR #50): the trie's claimable head is gone, `[ x, …xs ]`
copies, `prepend_in_loop` warns, core and platforms build at the end, the withdrawn
building-loop rule stays withdrawn. Research 72 on Bonsai (PR #49): nothing there is ahead of
write sets; a subtree-sharing `Dict` diff is the one idea worth a spike (parked). Split
`browser/tea/ApiAndRoutes` into `ApiLogin`, `ApiItems`, `Routes` for the budget (PR #52), the old
program kept as a size benchmark app. Briefed runtime slimming for direct and the per-process
checking cost.

**What I learned.** A kill criterion measured on an intermediate shape can blame the wrong thing:
break the bytes down before accepting it. `docs_test` prints informational output that Zig shows
under "failed command" even when the gate exits 0 — read the exit code. A schema-using Tea page
costs ≈ 3.5G instructions to build and run, which leaves the browser fixtures little budget.
An implementer brief must order spec before code and name the fixtures not to rewrite.
