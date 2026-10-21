## 2026-10-21 18:35 CEST — a spread walks only what its summary gained

**What I did.** Issue #607 (cause 3 of `plans/build-profile-2026-10-21b.md`). Each field
summary keeps an append-only log of the properties it gained (`Summary.log`); each spread
constraint keeps a cursor per spread of a name (`Cons.spreads`, `Pts.Cursor`); a re-evaluated
spread walks only the log past its cursor (`spreadSince`). The whole summary is walked at a
constraint's first evaluation, after its operand's var split (#568), and when more than half
the log is new. Four counters (`spec_pts_spreads`, `_spread_full`, `_spread_resets`,
`_spread_props`), two unit tests (a woken spread copies only new properties; a split resets the
cursor; both against a whole walk's facts), an *As built* note in `backend.md` §9. Every golden
and run hash unchanged; `spec_pts_edges` and `spec_pts_joins` equal on the dashboard programs.

**What I learned.** The profile's diagnosis was wrong in its premise. The 1 505 object
re-evaluations of N=64's third solve are spreads with an "unchanged value" only in the sense that
an object's value is always its own site; they are not walking an idle summary. The merged
widget summary gains properties one at a time in that solve, and 13 984 of the 51 368 properties
the whole walks met were new to the site and did real work (`shareField`, and copying each new
site property into the summaries holding the site). The 37 000 no-op revisits were cheap: fact 3
fell 1.2% at N=64 (sweep 3 68.4M → 66.7M instructions), 1.0% without `withDefault`, and wall
and `specialise` did not move. The first version, with no half-new rule, made
`MergedChildren` 1% dearer: walking scattered new ids loses the `indexAt` hints the whole walk
keeps. What remains of that solve's excess is new properties reaching spread sites and the
summaries that fold them, not re-walking.
