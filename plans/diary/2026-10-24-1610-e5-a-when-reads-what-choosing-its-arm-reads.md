## 2026-10-24 16:10 CEST — E5: a `when` reads what choosing its arm reads

**What I did.** #936's E5. The write-set pass now records, for a child hole whose value is a `case`
(an `if` is one) and an `Alt` on every visit, the anchors of choosing the alternative alone
(`Writes.Hole.selector`: scrutinee, tag facts, and the same for a nested join, not the arms'
values). Emit numbers it as a group, `Lower.Direct.Hole.selector_group`; the markup interface goes
to 1.19 with `HoleFacts.selector_group`; `inline.zig` registers an eager `when` in that group.
A guarded arm is untouched: `guardGroups` still gives its cohort the whole value's group.
Amendments: `browser-inline.md` §8.2, `write-sets.md` §3.6, `boundary.md` §9.4.6 (1.19). New
fixture `WhenSelector` (emit/release red on master; page transcript made before the change).
Three release goldens moved (ArmListener, ArmOperators, FormLocal), no page transcript.
One-file brotli of unique-components on top of E2: N = 64 −81/−51/−67, N = 256 −294/−229/−252
(seeds 1–3), about −1.0 B/widget on the 64→256 slope; N = 16 +3/−11/−32.

**What I learned.** Before building it, I checked the proof the plan asked for. Each value of an
unguarded arm is a write of its own with its hole's group, and it runs whether the arm is shown or
not. `when` only swaps the element and its anchor. A guarded arm (a value that may throw, or a
retained event binding) is the exception: its values are evaluated only while it is shown, by the
`when`'s own function, and that is why the cohort keeps the whole group. A fixture whose arm used
`String.fromInt` was guarded and did not move, which is how I found the case.
