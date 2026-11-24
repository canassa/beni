## 2026-11-24 14:42 CET — v3: Dict.update in a fold, Debug.todo arms, kept closures

**What I did**

- Lane prec211, a precision lane of v3 on `ownership-v2-design-review` (base 44a25c6b38). Targets in
  the brief's order: #2657's `SubscriptionTapFold`, then G1, G2, G4, G8a, G3 (#2652).
- **`SubscriptionTapFold`** (c7f91f2d25, kernel §12 item 8): a function parameter's supply keeps its
  position, so `Dict.update`'s callback value is apart from the values at the other keys; a walked
  body that runs its function once publishes `Fn.single`, so a capture it answers is at one place;
  the v3 word `hollow` (`Dict.empty`, `List.builder`) says the result holds no value at a type
  variable. It also wins the fold accumulators of `DictFoldLeft`, `DictFoldRight`, `FoldRight` (each
  keeps one other refusal), bench `DictExtra`, and two `ownership/` fixtures' safe declarations.
- **G4** (e1d5f58cab): `Js.throw` is `fresh hollow a`, so a `Debug.todo` arm answers no cell; four
  tea pages wholly accepted (`DefectInUpdate`, `DefectReleasesHost`, `WebSocketDirect`,
  `WebSocketLifetime`).
- **The first adversarial review** found six programs where `Fn.single` let one list captured under
  two names (`ys = xs`) be pushed twice; the caller now compares such captures with every other source
  (32425cfc71, `run/CallbackRunTwoNamesLive`).
- **G3** (b235ca5c56, kernel §6 rule 3): a closure's leaves are its captures' at the locations its
  contract reaches, wherever the closure is (a command, a tuple, an answer), not only where a holder
  keeps it. `NavigatePush` is wholly accepted; Conduit's `Login.update`, `LatestTagger`,
  `ListenerOrder` and `LogCommandContext` gain lines. The second review (about 255 programs) found no
  hole; its note on renewals is folded in on the pessimistic side.
- Evidence, base vs head: root dumps 60 refused→accepted lines, 0 accepted→refused; ledger 309 of
  319; sweeps dumped twice (dicts, callbacks-keep, handed-back, function-values, answers-beside,
  blind7f whole, the large ones sampled): 0 newly refused, 150 newly accepted, all safe twins; every
  newly accepted program SAME on the four legs; v3 on the real roots 1 916 → 1 885 ms (noise, a
  loaded machine); gates exit 0 at each push.

**What I learned**

- A function's own walk reads its captures as parameters apart from each other, and nobody promised
  that: any rule that drops a capture's `twice` must have the caller compare the capture's atoms with
  the other sources. The cell rows' `once` never needed it only because it keeps captures from outside
  the run `twice`.
- `fresh` on a row at a type variable names one cell at every location below it in a caller's wider
  reading. That made `Dict.empty ⊤` refuse its own fold and `Debug.todo` refuse all of `update`: a
  small word (`hollow`) was the fix, as #2578's option (a) said.
- Not done: G1 (the message is never `own`) needs a rule over every source of messages (sends,
  markup handlers that the runtime keeps, taggers of commands and subscriptions, maps); G2 needs the
  per-schema answer facts `schema.md` §6 describes, which v3's walk of the engine does not see; G8a
  (sternhalma) is a fold inside a fold's callback, whose fresh cells from each run share one name;
  G7 needs a callee that runs a closure once to let it write its captures. Each is larger than a lane.
