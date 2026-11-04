## 2026-11-04 10:27 CET — Typed DOM kernel committed; a cell-held array cannot be truncated

**What I did**

Took over lane wd-hf-dom. Fixed two shadowing errors in the uncommitted
protocol emitter, compared the inline corpus on the WIP against an exact
5db1842500 build (identical failure sets), and committed the protocol
emitter, linked Source field builders and the guarded inline bridge as
fd0f74f9a9 on hostfree-dom. The typed Slots module stays uncommitted.

**What I learned**

Typed Slots and typed Rows both keep their persistent native array in a
Js.Cell field and shrink it with Browser.Host.Array.rendererTruncate, which
is declared `written`. The ownership checker rejects that write ("the list
came from JavaScript"), because it cannot see that the cell is the array's
only holder. Rows hits it at Rows.beni:286 and Slots at Slots.beni:287. A
reduced case is a cell made with `Js.cell { items = Array.make ⊤ }` and then
truncated through `Js.cellRead`. push and set mutate the same arrays with
`borrowed`, so truncate is the only write the checker sees. Wiring rows
waits for a decision on this.
