## 2026-11-08 22:15 CET — Ownership v2 reads what a callback is supplied

**What I did.** Fixed #2297. `mapHelp`, `indexedMapHelp`, `filterMapHelp`, `foldlFrom`, `foldrFrom`,
`anyFrom` and `map2Help`…`map5Help` hand `traverseAt`'s or `at`'s element to their callback as a
temporary. A use is a local's (§2.7), so the temporary had no use, and the summaries said `reads π1ε` where
Appendix C says `[*] R`. The read-off (`ReadOff.factsOff`) now reads every parameter slot a direct label's
argument holds, deep, and every parameter arrival of a passed-on label's supply at the call's argument. The
spec gets an amendment in §2.11.3, *a supply is read*. The C golden loses its KNOWN MISMATCH note. A new
black-box test in `check_test.zig` adds helpers to a `--core-root` copy of core (direct, through `mapHelp`
and `foldlFrom`, and through a callee that supplies its argument), checks their summaries and the refusal of
the issue's program. It fails under `-Downership-v2-mutation=supply_no_reads`.

**What I learned.** The same root cause has a second half: a temporary argument to a contracted callee is read
through no footprint (`length (traverseAt xs 0)` reads `π1ε`). It is latent, because only `at`/`traverseAt`
answer what they do not read. Filed as #2302. `List.any`/`List.all` now keep their supplied element, because
`anyFrom` reads with `at`, so its recursive call reads `π1[*]`. A callback of theirs that writes its element
in place is now refused. `World.copyTreeInto(…, "")` copies nothing: every name starts with the empty
prefix.
