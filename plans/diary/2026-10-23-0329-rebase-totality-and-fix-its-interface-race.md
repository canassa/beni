## 2026-10-23 03:29 CEST — Rebase declaration totality and fix its interface race

### What I did

Rebased #645 (declaration totality, #618) onto master as its one own commit.
Master had bumped all three formats meanwhile, so the totality bump is now
interface 14 → 15, cache entry 13 → 14 and dispatch 14 → 15; the docs and
the one black-box pin of the entry version follow. Master's new
`key_compare` primitive (#294) is `String.compare` on a string key and
native order otherwise, so Totality treats it as `string_compare`.

Found the root of the intermittent "index out of bounds: index 3, len 0"
that #645's first full gate hit. `Totality.run` resolved `String.compare`
eagerly in every module, reading core `String`'s interface even from a
module that does not depend on `String`. Another thread can be publishing
that interface at that moment: a data race, and an answer that depended on
which module finished first. All interface reads in Totality now go through
one accessor that, under runtime safety, panics unless the module is a
transitive dependency; `String.compare` is resolved on the first comparison
primitive, and a module that does not depend on `String` has no proof. With
the old eager read and the new assertion, the build-time check of core
panics deterministically for several core modules (red); with the fix it
passes. The dispatch-row arity shortcut, a budget-era optimisation, is gone:
the solved scheme is the one source of "is this a function".

### What I learned

A module may read only its transitive dependencies' interfaces. The minted
type edges (`Graph.mintedModules`) make `String` a dependency of every
module that sees the `String` type, but not of one whose `key_compare` is
over a key type variable, such as core's `Dict`. A runtime-safety
assertion turns a schedule-dependent race into a deterministic failure.
