## 2026-10-20 10:23 CEST — representation keys in two JsIr columns

**What I did.** Built the lowering half of the declared-type filter
(#490), stacked on the checker's type-key artifact (#489):
`js/RepKeys.zig` merges every module's artifact into one table on the
calling thread before lowering, maps each type to what it is at run time
(an unboxed type is its field, its arguments substituted into the
field's written type), and closes the wild set. `Lower` fills
`JsIr.name_key` in `localName` and `JsIr.node_key` on the object, array
and arrow an allocating instruction makes; `Spec` clears a key on every
in-place rewrite, appended names and nodes are wild, and `Copy` keeps
keys only for a closed declaration. A safety build asserts at
`Pts.siteOf` that a keyed node is still an allocation. The hidden
`build --rep-keys` prints the table and the keys; `tests/corpus/repkeys/`
pins three programs and `cache_test.zig` a warm/cold pair. Nothing reads
the columns: every golden and run hash is unchanged.

**What I learned.**
- A `NameIndex` is not a local: lowering numbers a local within its
  top-level declaration, so `p$1` of two declarations is one name. A
  conflicting key makes the name wild; fact 3 keys locals per top-level
  statement, so a per-statement key is the fix if precision suffers.
- The first artifact keyed no declaration, so a top-level function's
  arrow had no key; the checker added one per declaration the same day, and
  the arrow now carries it, which is also what `Copy`'s rule reads.
- An unannotated `let` of a constructor of a generic type, or of a lambda
  over an extensible record, is generalised and keys wild; `List`
  functions' crossing quantifiers make any element type wild. Fixtures
  have to avoid both to show a closed key.
- Perl `s|…|…|` with `\|` in the pattern is an alternation, not a literal
  pipe: it silently rewrote two unrelated lines of `Emit.zig`.
- A dense node column cost 23 % of `JsIr` bytes on `bench/corpus` for
  words almost all wild; rows for the keyed allocations alone cost 3 %.
