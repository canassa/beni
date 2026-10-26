## 2026-10-26 12:40 CET — ownership v2: result selectors and write-backs

**What I did.** Built the words the owner approved for #1052, through the
front end and into `Rows`. `elementof`, `copyof` and `prepended` are result
words. `stored` on a function parameter stores the callback's answer: back at
the element it was handed (`once taken stored`, with a `written returned`
first parameter), or into the cell beside `cellupdate`/`cellmodify`, which now
need it. Lowering checks the companions under two new readings of
`misplaced_ownership_word`. The words route their signature to the v2
column. `Rows.fromWords` gives each row as §2.13.6 does, and a stored
callback's answer becomes a write-back record on its fun (`Summary.Back`:
the selected path of the answer, the destination, element or cell, and
whether a Maybe answer's `Nothing` removes). It replaces the old `need` on
the whole answer. Summary joins, orders, normalises and prints the records,
and the block carries them (block format 6). I worded `List.at`,
`unsafeGet`, `copy`, `sliceOf`, `sortWith`, `cons`, `focus`, `Ref.update`
and `Ref.modify`, and pinned their bodies and the helpers they run.

Evidence: `bench/ownership-everywhere.mjs --diff=v1,v1 --same` gives
byte-identical reports with a master binary and with the branch binary
(10 957 demands, the same verdicts). All 634 `run/` fixtures, built in dev
and in `--release --allow-debug` with both binaries, give identical `.mjs`
files. Only dev source maps and manifests change (382 dev builds), because a
dev map embeds core's source. The run hashes were recorded again, and only
`dev*` and `fuzz` lines moved.

**What I learned.** `Summary.zig` was at 1 397 of its 1 400-line target, so
any new class field needed §5's target to grow (now 1 500). The class record
is exactly 64 bytes, so the write-backs went on the fun record, not on the
class. Perl `s|…|…|` with `\|` in the pattern makes an alternation, not a
literal `|`. That corrupted a file once; for multi-line edits, use the edit
tool. `Ast.OwnWord` is `enum(u5)`, and with these three words it is full
(32 values). The next word needs a wider enum and wider word bits.
