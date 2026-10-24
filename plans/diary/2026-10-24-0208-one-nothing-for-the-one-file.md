## 2026-10-24 02:08 CEST — one Nothing for the one file

**What I did.** One item of #916: one shared `Nothing`. Each widget module that builds core's
`Nothing` declares its own constant (`backend.md` §4, *A nullary constructor is one object*:
per module, because one per program would need a file to import it from). A release application
is one scope-hoisted file, so `Emit.shareNullaries` keeps the first declaration of each imported
nullary constructor, in the file's order, drops the later ones from their modules' plans, and
numbers each dropped name as the first one. Spec: §4, amended. Fixture, red first:
`emit/release/app/NullaryShared`. The seven release goldens it moved fell by 132 B in total.

S1 (one-file brotli, my build, against the dead-tags branch): the 64→256 slope fell by 3.2, 2.9
and 2.5 B per widget over seeds 1–3. N = 1 is unchanged, since it has one widget module.

I also filed #927. `run/HttpServerBadClients` counts the handlers that ran before `/stop`, and
under a loaded full `test-blackbox` it wrote 6 where the golden says 7. Run alone it gives 7
every time.

**What I learned.** The globals table and the plan's bit sets belong to different allocators:
`Rename.Globals.map` is the emitter's scratch and `plan.dropped` is a worker's kept arena,
sized for every node. A slice I put in place of `plan.dropped` was freed later as theirs. The
plan is written in place, as `pruneOptimised` already does.
