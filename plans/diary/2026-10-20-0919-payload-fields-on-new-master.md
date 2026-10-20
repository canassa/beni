## 2026-10-20 09:19 UTC — payload fields on the new master

**What I did**

Rebased the payload-field fix onto `upstream/master` at `697b77fc6`.
The field-summary read in `e3a6e38a7` did not cover the case. On that
master, with this commit's golden and without the `Spec.zig` change,
the payload worker was still `return{a:{c:g,b:f}}`.

The cell already keeps the objects beside `top`. The binding was a
capped local, so the join escaped them. The binding is now uncapped,
like the cell, and `limited`, so `max_sites` still applies. Clearing
`top` on the join instead changed the schema cursor and was reverted.

`MemberReadsWide`, the wide member-read program, built in 373 ms
before and 373 ms after (ReleaseSafe, `--release --no-cache --jobs=1`).
Both wrote 21 053 bytes and the files matched.

**What I learned**

A summary marks the field that was asked for. It does not stop the
next var from escaping the objects the cell kept. The cap and the
`top` flag are separate. A member binding needs the second without
losing the first.
