## 2026-10-23 06:42 CEST — recursive schemas fold, and a marker stands where its type is (#820)

**What I did.** Gave native schema constructors a type in the ownership type graph. Each
endpoint, `Type` and `Encoded`, is its own key (`Encoded` sets bit 31 of the declaration), its
heads come from the schema plan, and a constructor's payload level comes from the plan's nodes.
The naive fold refused a safe program that master accepts (`SchemaLevels.after`). The reason is
that every schema payload is a record, so the region's marker stood below `#Link.0` and overlapped
the root's own fields. So I made the #379 marker precise: a constructor field's *anchors* are the
written paths (fields, tuple slots, list elements) to a `T`, and the region's marker stands there,
at a `T`. The canonical form reads and writes the anchored places. The block marks `Encoded` in
the marker's kind byte (version 35). `ownership/SchemaLevels` pins the schema analogue of #286's
hole, which is red on master. `RecordBaseLevels` pins #404, now fixed, and its twin.

**What I learned.** Anchoring through `kids[*]` fixed #404 and made `RecordTree` and
`LevelPlacesKinds.demoRose` pass the full cross-check. `demoA`, through `Maybe`'s constructor,
still fails as on master (#694). A full-cross-check binary run on a scratch copy of the fixture showed
that master fails `demoA` too: master stops at `demoRose` first.
