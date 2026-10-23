## 2026-10-23 17:49 CEST — root closures, registered readers and the loader

**What I did.** Built #668's whole shape (`browser-inline.md` §8.4, amended 2026-10-22) in one
switch. The serial pre-pass makes a root plan per program (`Emit.buildPlans`): roots in placement
order, which model paths keep their object, how each root reads the arguments of its function,
a table of rows and buckets keyed by the read paths each root owns, and the buckets each read set
and each key selects. Interface 1.17 hands it to the lowering. `inline` writes each piece's root as
one factory, `$$root$n`, that makes its binding entries, adds them to their buckets — another
root's too — and wires its events; a key whose program arm is a pure forward is handled inside the
root, the rest are the program's and handed in. The runtime has `entry`, `pass`, `passes` and
`first`. Pushed state goes through routes: the write-set pass finds `F x model.f` tails, `F` a
`Result.withDefault D old`, and the lowering writes each as the loader's copy into the old object,
with rows as data. Twelve new pages and goldens, three bad builds, a cache differential test, and
the `./rr check` matrix.

**What I learned.**
- A `node` write says nothing about identity: the snapshot's record literal at ρ is `node ρ`. The
  plan reads identity off the key's result term instead — `Rec` over its own path, written in
  place only in a clean module — and treats a program that walks a spread update (a project's
  platform layer) as keeping nothing.
- The replacement proof the amendment feared needed no change to the ownership checker: a route is
  a tail with nothing on the way reading the model, every function on the way called only there,
  `F`'s result old-or-fresh, and no command that could hold an old object; the entry's exclusivity
  does the rest.
- A root with no hole has no call path in the pieces pre-pass; the view walk's parameter facts
  give it. Found by `./rr check` at N = 256, not by the corpus, so `RootNoHoles` pins it.
- Every new page's transcript matches `browser-tea`'s for the same sources, once both platforms'
  anchors are normalised: a cheap, independent oracle for a new lowering.
- Another agent shares the scratchpad's `wt` directory name: use a name of your own.
