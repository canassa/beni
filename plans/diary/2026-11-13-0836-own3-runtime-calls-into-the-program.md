## 2026-11-13 08:36 CET — own3: every call the runtime makes into the program

**What I did**

- Fixed the faults that blind readers C and D found (reports 121 and 122), one rule at a time.
  - **Entry (kernel §6.13).** Every function of the record now needs a contract. Each value of a `join` is
    applied, and a function with no known code means no model location is `own`.
  - **Where the model is.** It is read off the entry's declared type (`Mod.entryShape`), so a tuple
    model under `model × Cmd msg` is found at its item.
  - **Markup (§6.12).** The markup holds each closure its holes make, and every helper hole, text holes
    included. A component's children are a prop. The runtime calls `For` rows, key functions and `Show`
    bodies with items, and those calls are now applied as at a call site (`formCalls`, `runtimeCall`).
- Wrote research report 123 and revised kernel §5, §6.12 and §6.13.
- Gate results:
  - sweeps: 453 traps before, 0 after, on 77 618 programs;
  - sanitiser corpus: 0 traps before and after;
  - real writes: the same 287 of 308;
  - speed: 846k lines/s before, 840k after;
  - `zig build gates`: green.

**What I learned**

- A `v_none` function value is not always a constructor. A field of a top-level record whose contract
  holds no cell also projects to `v_none`. So only a constructor written at the field counts as code that
  keeps nothing.
- The reviewer found that a `Show` keyed by identity compares a kept list with `===`, as a by-reference
  `For` does (#2504). The sanitiser cannot see a fault of that kind. Only a build that edits in place
  shows it.
