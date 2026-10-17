# `browser-inline` — the analysis rules and the error taxonomy

*2026-10-17. The normative part of the second direct platform, `browser-inline`, which the owner
ordered built from its output (`plans/direct-rewrite.md`). **The output is the specification**:
what a program compiles to is pinned by goldens taken from tea-inline
(`../reactivity-research/frameworks/tea-inline/`), under `tests/corpus/emit/inline/`,
`emit/release/inline/`, `build/bad/inline/` and `browser/inline/`, and this document holds only
what a golden cannot show — which facts the lowering takes from which analysis, and which programs
it refuses, with what. It grows one section per slice; section numbers are never renumbered
(CLAUDE.md rule 2), and a later change is a dated amendment in place.*

## 1. The platform

`platforms/browser-inline/` depends on `html` alone. It imports nothing of `browser`'s, of
`browser-tea`'s or of `browser-direct`'s — no `Rt`, no `Hosted`, no driver, no `core/Task`, no
`core/Dict` — and its runtime, `Inline.beni`, is beni over `Js`. Its markup lowering is `inline`
(`platforms/browser-inline/zig/`), a program lowering (`boundary.md` §9.4.6, version 1.6 on): a
program is compiled whole where its constructor is called, and there is no run-time renderer to
fall back on.

| Module | What a program may use |
|---|---|
| `Browser` | `Program`, `mountAt` |
| `Tea` | `Program`, `sandbox`, `element` — `browser-tea`'s signatures, so one source builds on both |
| `Cmd` | `Cmd`, `none`, `batch`, `perform` |
| `Sub` | `Sub`, `none`, `batch`, `map`, `on` — `browser`'s signatures; there is no `listen` |
| `Listen` | `on`, a listener on the window or the document |
| `Html` | `html`'s vocabulary, re-exported |

One program per page: `Browser.mountAt p id` mounts it at the element `id` names, and a program
not placed mounts at `document.body`. The runtime exports `run` and `stop` (`boundary.md` §9.4.5,
amended 2026-10-17).

## 2. What the lowering takes, and from where

The lowering re-derives nothing. Every fact below is an analysis's, through the markup lowering
interface:

| Fact | Analysis | Interface |
|---|---|---|
| the message keys, each key's arm, which bindings each key's writes reach | the write-set pass (`write-sets.md`) | `programKeys`, `programArm`, `programCalls`, `programHole` |
| what the subscription set is | the write-set pass, evaluating `subscriptions ρ` (§3) | `programSubscriptions` (version 1.14) |
| what each key's command is, and `init`'s | the write-set pass, evaluating the arm's result (§4) | `programCommand` (version 1.14) |
| whether a command's body may suspend | the checker's effect inference (`checker-v2.md` §26) | `programCommand` |
| whether a list is edited in place safely | the ownership checker, through the manifest's `"lists": "in-place"` | — (its refusals are its own) |

## 3. Subscriptions

The pass evaluates `subscriptions` applied to the model's root ρ, walking the platform layer's
functions (`Push.onPush`, `Interval.every`) as it walks the program's, and recognising the four
values of `Sub` by name. The set is the **flat list of `Sub.on` declarations** the value is made
of, in order: `batch` concatenates, `map` composes its function onto each declaration's tagger,
`none` is no declaration.

- **The set must not depend on the model.** A value whose shape, or any declaration's key, reads
  ρ is refused (§5, class 3): a set that changes needs the subscription diff, which is slice S4's.
- **A key is a constant**: a literal or a constructor of constants, whatever the module it is
  written in. Two declarations with equal keys are **one resource**, merged at compile time: the
  first one's `start` runs once, and each value it sends goes through every declaration's tagger,
  in declaration order (`boundary.md` §9.8.5's rule, decided when the program is built).
- **A tagger resolves to a key.** Applied to a fresh payload π, the tagger must give a constructor
  of the message type each field of which is π itself. Its key is the leaf of the program's key
  tree whose steps that message satisfies: a step naming the constructor, a default step whose
  constructors include it, or no step at all (a message type `update` does not split, one of one
  constructor among them). The value the start sends then calls that key's handler directly — no
  message is made. A tagger that gives no constructor of the message type is refused (§5, class
  3); one whose key splits further, on the payload's own shape, is a limit of the compiler (§5,
  class 4), since only the handler could tell.
- **`start` must not suspend**: `Sub.on`'s `start` is `sync`, so the checker refuses one that
  does, before the lowering sees it.

Each declaration compiles to the start applied to a send that enters the dispatch guard with the
key's handler; what it returns, the remover, is one of the program's disposers (`stop`).

## 4. Commands

The pass evaluates each key's arm — and `init` — to its `model × Cmd msg` result and reads the
command half, recognising `Cmd.none`, `Cmd.batch` and `Cmd.perform` by name:

- `Cmd.none`, and a `batch` of nothing but `none`, is **none**: the handler writes no code for it;
- a `perform` whose body cannot suspend, by the checker's answer at that call, **runs**: after the
  handler's write pass, in the same dispatch, through the guard's queue (`boundary.md` §9.8.4,
  amended 2026-10-17);
- a body that may suspend is refused (§5, class 2);
- a command the pass cannot read as one of these is refused (§5, class 4).

## 5. What the lowering refuses

Strict, not coarse: what the lowering cannot compile exactly is a build error, `not_implemented`,
at the program's call or at the construct, and never a fallback. Each message says which class it
is, what the cause is, and what to write instead. There are four classes.

1. **Not supported on browser-inline yet** — a construct a later slice of
   `plans/direct-rewrite.md` §5 adds (S1: events and holes beyond the one text binding; S2:
   `For`; S3: a `view`'s `let`s; S4: a set of subscriptions that changes, `Show`, branches; S6:
   the task kernel). The message says *"not supported on browser-inline yet"* and what to write
   instead; it names no slice and no plan, which are this document's and not the user's.
2. **Needs the task kernel** — a command whose body may suspend: *"needs the task kernel, which
   is not supported on browser-inline yet"*, with the body's position. The kernel returns behind
   reachability in S6.
3. **The program's shape** — what the platform's model cannot express exactly, with what to write
   instead: a subscription set that reads the model (*"… depends on its model …"*), a tagger
   that gives no message constructor of the program (*"… give the message a constructor that
   takes the value …"*). A tagger that gives a constructor whose key the analysis splits on the
   payload's own shape (`Pushed (Box v)` with `update` matching on `Box`) is class 4, not 3:
   the program is valid.
4. **A limit of the compiler** — a fact the analysis did not give, or code the compiler cannot
   write where the lowering needs it. The message says *"a limit of the compiler"*, so it is never
   read as a rule of the language, and names what would lift it.

## 6. The release ledger (`plans/direct-rewrite.md` §8, as the owner decided for S0)

- **The dispatch guard and the mid-dispatch send queue are kept** on every page: a defect stops the
  page (`try … finally`, no `catch`), and a send made while a dispatch runs is queued.
- **The mount fault is development's.** A development build marks the mount node (`$$root`) and
  throws *"cannot mount at …"* for a node that is missing or already holds a program. A release
  build ships neither; a missing node still fails **inside the dispatch guard**, so the page stops
  as for any defect, without prose, and no `TypeError` escapes the entry unguarded.
- **No message object, no `switch` and no error prose in release** for what S0 compiles: a key's
  handler is called directly. A pushed value decoded with `Schema.read` whose `Err` payload is
  never read is to be a validator (`schema.md` §6, amended 2026-10-17): specified, **not yet
  built**, so a compiled run still ships its issues' prose.

## 7. Lifted pieces: another module's code at the program site

*Added 2026-10-17, the owner's decision (option 2 of the S0 report's wall).* A program site — the
mount and the handlers the lowering writes in the module that calls the program's constructor —
needs code that is written in other modules: a subscription's start is a lambda inside a layer's
`Push.onPush`, which calls that module's private `detail`. The compiler lowers each module on its
own, in parallel, so the program module cannot write that code itself.

**The mechanism.** Each module lowers its own pieces, as exported top-level functions, and the
program site calls them.

- **Which pieces.** The write-set pass, which already runs over every module, serially and
  deterministically, before the modules are lowered, says which: for S0, every subscription start
  that is a lambda (§3). The set is general: S1's per-key arms of `update` are pieces of the same
  kind.
- **What a piece is.** `<Module>$<declaration>$$lift$<n>`: the lambda, lowered in its own module
  where its declaration's other code is, as a function of the locals of that declaration it reads
  (its captures), whose value is the lambda; a piece with no captures is the lambda itself. `n` is
  the lambda's place among the lambdas of its declaration, in source order: the name never names
  an instruction, so it does not move when other code does (CLAUDE.md rule 5).
- **What the program site knows of it.** Its name and its captures, in order — never its body. The
  program module still lowers in parallel with the others. At the program site each capture is the
  value the pass found for it, which must be a literal (`Interval.every 1000` captures `1000`);
  a piece that captures anything the program site cannot write is refused as a limit of the
  compiler (§5, class 4).
- **Reachability.** A piece is a node of its own (`backend.md` §9): reached from the program call
  that uses it, and reaching what its own instructions name. The value a program record's
  `subscriptions` field names is not reached through the record, since the program site never
  evaluates it, so a layer's `onPush` and `Sub.on` ship only if something else uses them.
- **In release**, the release optimiser fuses a piece used once into its listener where its rules
  allow; a development build shows each piece as a call, which is accepted.

**Rejected: writing the other module's code at the program site** (option 1). It specialises code
per program instance, the first platform's cause 3 (`plans/direct-rewrite.md` §1), and it makes a
module's output depend on another module's body at every use, which incremental lowering cannot
cache by module (`fast-compiler.md` §8.1, amended the same day).
