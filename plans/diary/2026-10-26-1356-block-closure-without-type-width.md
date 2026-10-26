## 2026-10-26 13:56 CET — block closure without type width

**What I did.** Answered #1077's verification. `Writer.successors` no
longer projects every step of a position's place type: written positions
are closed under their nodes' parts and the routes to stored κ only, and
those routes come from `extras_made`, not from a scan. The writer's κ
reads and projections run on a codec account whose allowance is the
lane's room, settled into the lane. Growth is now counted per class as if
it were alone in the block: the value positions it reaches past one per
node, never walking through an owner record, which lists every class's
values. Rebased onto #1079; `back` records fall in tier 0, beside keeps
and slots.

**What I learned.** Per-class growth via a walk from each class went
quadratic until owners were excluded: one owner names the values of every
class under its map. The frontier search for an entry stored below a
node's parts still scans a place's steps, but only while a map has an
entry not found yet. That stays until κ maps carry their paths.
