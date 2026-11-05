## 2026-11-05 05:20 CET — Prove the 62 v2-accepts rows; one hole in entry

**What I did**

- #1949. I took the 62 rows of `ownership-v2-known.txt` where v2 accepts a demand that v1 refuses, in fixtures that do not run. For each row I wrote a runnable twin of its shape, with adversaries, under `~/.cache/beni-agents/slot-build/proof/` on dagon. I built each twin plain and with `--ownership=v2 --ownership-everywhere --sanitize-lists`. `run.sh` checks that the named write is wrapped, and `sites.mjs` maps each wrap's byte offset back to line:col.
- Results: 17 rows are safe and their write runs (wrapped, the same output). 44 rows are safe because no store happens: v2 refuses the program at the enclosing call, at the callee's own write, or at the closure. One row was a hole.
- The hole: `EntryMalformedSettle`. v2's `Rows.fromWords` read the `entry` word as a borrowed record. So a `settle` of an unsupported shape wrote in place with no caller to check. A probe platform whose runtime reads the old state after `settle` printed `2 2` instead of `1 2`. The fix (`79d7e0288d`) applies R-5.8.1: v1's shape test (`Prepass.entryProtocol`, read from the worded declaration's annotation) and, on a failure, no word, so the record escapes. The new fixtures are `run/SanitiserEntryUnsupported` (`-refuses`; I showed that it fails before the fix) and `run/SanitiserEntrySupported`. I amended the spec in §2.13.4 item 4.
- `0273f1d30e` names each row's proof in its reason. The oracle (1 332 + 118 probes) has 0 TRAP and 0 DIFF. The ledger from base to head has a2r 0, r2a 0, and 2 new refusals, both the hole. The cost table is identical. Gates are green. I posted the table on #1949 and the status on #1685.

**What I learned**

- Most of the "v2 reads the parts apart" rows are not about precision at all. v2 accepts the callback's own write `param` and refuses the enclosing `List.map`, `foldl` or `update` instead. Today v2 refuses every push in a `List.map` callback at the map, even over fresh elements.
- v2 builds no entry protocol yet (S7): a well-formed TEA `update` write is `param` with no caller, which is sound only by the trusted runtime (P1). An `entry` of any other shape had the same free pass until now.
- The sanitiser cannot trap a stale `List.length` read (§7.3's specified limit). This hole showed only as a DIFF, so a probe must print the lengths, not only index into the list.
