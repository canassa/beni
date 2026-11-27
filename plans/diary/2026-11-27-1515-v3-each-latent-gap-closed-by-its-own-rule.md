## 2026-11-27 15:15 CET — v3: each latent gap closed by its own rule

**What I did**

- Hardening lane hard234 on `ownership-v2-design-review` (base 127cce0419), #2712: code readers
  CR14 and CR15 found seven gaps that another rule closed. Each now has its own rule; every
  change refuses more and accepts nothing new.
- CR14 U1: kernel §13 item 12 (e) now says what `renewHandleOf` does (a `.version` entry has a
  name of its own, with its old names beside it, `dead` set). Safe builds check it
  (`checkOldNames`, a §9 row).
- CR14 U2: a run that writes its captured cell's contents is refused where another cell the frame
  follows holds the same list (`heldInOtherCell`, beside `heldAtOther`).
  `run/CellTwoCellsOneList` and its live twin. With the rule reverted, the live twin is refused at
  other places, by the operands of switch points.
- CR14 U3: every fallback of `Mod.edgeEffect` says `hosts`, so `evidenceAt` refuses such evidence
  as hosting by its own rule (`check/bad/inline/HostingEvidenceBoundToValue`).
- CR15 U1: `fieldCall` (through `methodCall`), `eventCall` and `runtimeCall` read the applied
  contract's hosting facts (`knownRuns`) (`check/bad/inline/HostingFunctionInField`).
- CR15 U2: a view root of another module is now a positive fact. Its module publishes it
  (`Published.views`), and each importer refuses a reference that is not a piece of a view's
  markup (`checkPieces`), dot-calls and evidence included. An entry record's own `view` field is
  allowed. Fixtures: `check/bad/inline/ViewOfAnotherModuleInRow`, `ViewOfAnotherModuleByMethod`.
- CR15 U3: `run.mjs` has a fifth leg, the build users get on a chain that names v3 (no flag;
  development and release; SH*/RSH*).
- CR15 U4: `FlowKey` keys `Use.held`, `Use.di` and `Use.entry`.

**What I learned**

- The fifth leg found a real difference at once, on the base too (#2729). In
  `browser/inline/ShowAndBranches`, a `Show` keyed by identity keeps its body after `update`
  writes the record in place. The copying build mounts a new body, and `browser-tea` does the same.
  The committed golden holds the in-place transcript.
- The first positive form of U2 (a view root only where an entry's record names it) refused three
  safe corpus pages: another module's view shown as a piece (`PieceHandler*`). The positive fact
  had to live at the importer, because the module that defines the view cannot see its uses.
