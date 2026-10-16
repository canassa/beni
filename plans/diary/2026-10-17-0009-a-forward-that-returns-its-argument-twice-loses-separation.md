## 2026-10-17 00:09 CEST — A forward that returns its argument twice loses separation

**What I did.** Issue #268. §30.10 drops a conversion's `forward` argument from the schema's decoding slot,
because the run built it. A `forward` that returns it at two places (`λxs → Ok ( xs, xs )`, a record with
two fields of it, `( xs, [ xs ] )`) put one array at two positions of the answer, and `( List.push a 9, b )`
was accepted; the library path through `Schema.converted` too. Now `functionAnswer` asks
`namesArgumentTwice` of the forward's summary: one part of the argument at two result paths that are not
one placement puts `⊤twice` in the slot, with a message of its own, and a write onto the answer is
rejected `unknown`, approximately. `partTracked` follows the argument's type down the path, so the `Int`s
of a `List Int` found again in `List.reverse xs` do not count. Spec: a dated amendment in §30.10. Fixture
`ownership/SchemaConversionTwice`, red before (all five accepted). `bench/ownership-everywhere.mjs`: 0 of
850 programs rejected.

**What I learned.** The elements of a run's answer were already "may share one list", so only distinct
tuple slots, record fields and constructor arguments were wrongly separated. A summary's `[*] ~π1[*]` entry
exists for a `List Int` even though its elements hold nothing, so a check over summary paths needs the
type filter. A `⊤` flavour must not reuse a number another open branch takes: two constants with one value
merge without a conflict and print each other's message.
