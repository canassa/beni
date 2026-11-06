## 2026-11-06 18:44 CET — the lint and the wider supply

**What I did.** Took #2135's third review. The lint now reads `std.mem`'s compares by name on anything but bytes, aliases, `std.meta.eql` and words as bytes, with a named exception per line; three mutations of `Held.zig` each fail it. `PlainReach` reads its keys by `SlotWords` when a row is among them. `Forest.at`'s callers are decided. A label passed on at a site that names more pairs each of the row's steps with the argument's own step (`ReadOff`), which clears the `wid` family.

**What I learned.** Falling back to the full `instSel` in `PlainReach` was sound and cost 71 accepted programs, all `foldu`, which a wider key compare keeps. "A miss must not relax" asks for an answer that errs toward a hit, not for no answer.

§2.1 claimed the lint closes the class. It does not, and no text search could: a hand-written loop and a compare of two `Rel` ids pass it. It says so now.

I killed my own shell with `pgrep -f` on a string in my own command line. Kill by the pid `ps` shows.
