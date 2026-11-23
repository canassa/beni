## 2026-11-23 17:25 CET — keyed commands on browser-inline

**What I did.** `browser-inline` compiles `Cmd.keyed`, `Cmd.cancel`, `Cmd.cancelAll` and `Cmd.map`
(#2615; `browser-inline.md` §4 and `write-sets.md`, amended 2026-11-23; interface 1.32). The
write-set pass reads a keyed command as its body, a cancellation as work with no body, and a map
as its command's bodies. `Inline.beni` keeps a table of the bodies running under each key path per
program: an item changes the table where `commands` reads it, and the body starts as an unkeyed
one does. 11 `browser/tea` pages were copied to `browser/inline`: 8 have tea's transcript, and 3 name
a listed difference. Also 4 new pages, 2 `build/bad` fixtures turned into pages, and 2 release goldens.
`HttpCancel` now stops at another limit (an `update` that reads its message whole), also with
`Cmd.perform`. The inline sweep of the 357 tea/dom pages went from 139 to 149 with the same script
on the same master.

**What I learned.** The adversarial review found two holes that the port took from `browser-tea`'s
table. `Queue` kept only its newest body under the path. And a child's `cancelAll` also stopped the
parent's key that equals the child's segment. Inline now does what `boundary.md` §9.8.2 says, and
#2627 records tea's two holes. `Cmd.batch [ if c then x else y ]` was unread for every command, not
only keyed ones: an `Alt` was read only as the whole command half. The union of the alternatives
is exact for what the reader answers. The DCE rule for constructors that nothing builds keeps the
fiber runtime out only when the call that spawns is lexically inside an `InFiber` arm. A guard
through a helper that returns `Bool` does not keep it out. On inline, a body that never waits has
ended by the next click, so tea's two-clicks-in-one-task pages differ; `KeyedBatch` asks twice in
one `update` instead.
