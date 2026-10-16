## 2026-10-16 02:30 CEST — schema cycles rebased over derived codecs

**What I did.** Rebased #215 (schema declarations that name each other) onto
master after slice C (#206, derived codecs). The conflict was in
`SchemaLower.zig`'s description generator: slice C's new arms (`codec_ref`,
`maybe`, `tuple`, `constructors`) still took the old `self` parameter. They
now take the `scope` of cycle cells, and `reference` and `codec_ref` share
one `descRef`, so a codec's reference to a cycle member with the parameters
as they are reads that member's cell. `cycleMembers` now walks the module's
derived codecs too (virtual declarations after the last one), `cycleCells`
names a codec member `codec` and the declaring codec's cells are wrapped in
`describedHost` as its plain description is. New fixture
`run/JsonDerivedDescribe`.

**What I learned.** A derived codec at a concrete type is monomorphic — a
constant, never in a generic cycle — so master described those finitely
already. The overflow needs a codec derived where the type variable stays
the caller's (`where a.codec`): `Rose a` and `Grove a` then each take `a` as
a parameter, and master's `describe` of them overflows the stack in
`shapeOf`. The fixture covers both. A full `/tmp` (other sessions' builds)
made `git rebase --continue` lose a commit step twice; committing with
`git commit -C <orig>` and continuing recovered it.
