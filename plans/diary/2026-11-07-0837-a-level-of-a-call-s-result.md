## 2026-11-07 08:37 CET — a level of a call's result

**What I did.** Fixed #2195 on top of #2194. An open arrival of a result is now also said at each fold target above its slot, by every route (`LevelWide.of`, from `Put.arriveWide`). Four fixtures `run/SanitiserLevelResult*`, a mutation, O6's row, a generator over result sites.

**What I learned.** The reader cannot fix this well: `atSlot` has eight consumers that index words by a hit's depth, and a route's words are not the caller's. Said at the fold, the tree stays canonical and every reader works unchanged, with exact arrival slots. It costs nothing on a type with one recursive place, since a first return's own levels fold below it. An earlier claim of mine in #2194's first text called every new refusal needed: the `narrow` ones are false refusals, a slot that cannot tell two callees apart, and I should have said so.
