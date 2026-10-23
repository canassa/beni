## 2026-10-23 21:30 CEST — a route's function reads `old` only as a tail (#896, first part)

**What I did.** I read #896's four causes in S1's own output. Causes 1 and 2 are one cause. The
`unique-components` generator writes a widget's `replace` in two shapes. The first is
`Result.withDefault (Json.decodeValue state) model`. The second is
`case Json.decodeValue state of Ok new → { … from new … }; Err _ → model`. `Writes.routeFunction`
accepted only the first. At N ≥ 16 some widget always had the second shape. So the `Snapshot` tail
stayed a record literal of the model, `Key.replaced` held ρ, and the root plan made the whole model a
cell. Every handler then stayed in `Main`, because a moved handler needs a `held` slice. The
forwarding proof (`update` → `step` → `{ model | wN = WN.update m model.wN }`) already held. A route's
`F` is now any function that reads `old` only as a whole tail, through `let`s and `case`s that do not
read it, or as `Result.withDefault D old`. All 12 S1 builds (N 1–256, seeds 1–3) now hold every slice
and move every widget's handlers into its root. n256-s1 raw fell from about 393 k to 334 k. Spec:
`browser-inline.md` §8.4 and `write-sets.md`, amended. New page and golden: `CaseLoader`. The
`ErrorUnreadWidgets` golden moved: its three widgets are now routes. `./rr check` passed 24/24.

**What I learned.** The proof's weak link was a pattern match on one spelling of "the result holds
nothing of `old`". The property it needs is structural, and a tail walk states it directly. When
`./rr check` runs with `TMPDIR` inside a deep worktree path, Chrome dies with "Socket path too
long". Use a short directory under $HOME.
