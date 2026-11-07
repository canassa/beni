## 2026-10-31 18:13 CET — own2: rule 3 after its review

**What I did**

- Fixed the review of #1500 in `Calls.zig`.
  - Condition (b) now walks the actual down the common prefix (`onePositionAlong`). One position must
    be met before any `[*]`. Below `[*]`, a union is two elements, and a leaf can be one object at two
    indices.
  - Rule 3 now takes k ≥ 2 sides in one linear pass. It keeps each shared image on its first side, and
    adds `apart` among two or more shared images, so a cross pair is not dropped.
  - (c) is a `runtime_safety` assert (`namesPositions`). A release build keeps a failing image as a
    repeat.
  - The check is now a traced preimage of the whole actual. Every source state that brings a shared
    image to a callee path must stand at one path with no summary step, which covers the cross case.
- Added fixtures `o/LevelPositionsElems` (and imported), `o/LevelPositionsWide` and
  `o/PushedTwiceLevels`.
- Added counted tests over k list fields, and a test that rule 3's atoms cross a block unchanged.
- §2.9 is rewritten to match: (a) is reached but kept strict, and the side effect is noted.

**What I learned**

- "One position" is a property of a route, not of a node. The same union is one position's possible
  contents above every `[*]`, and two coexisting elements below one. Testing the node alone was the
  bug, and the panic in the old check was the symptom.
- A check per key cannot see one object that lands at two keys. Tracing the source state of each
  arrival can, and it costs nothing outside safety builds.
- The k-field family costs about k² records on master already (the class's size). Rule 3 adds 1.5–1.7×
  there, through two more walks per member.
- `g ys = incAll (B ys [])` now publishes `excl` atoms below `ys`'s elements. So handing it a list that
  holds one element twice is refused. v1 and master accept that, which is the #1478 class, and it is
  now pinned by a fixture.
