## 2026-10-23 13:57 CEST — read the flat fragment's array shapes from the types

**What I did**

- Slice 2a of #522 (the plan is on #522, 2026-10-23, and in `PROOF-PLAN.md`, *Dictionaries*). The heap clause `FlatHeap` ("every array holds integers") and the invariant field `heapInts` are gone. `AllocatedFlatValue.list root integers` and `chain` carry `heap[root]? = some (heapInts integers)`; `allocated_of_typed` reads the integers off the binding's typed expansion (`integers_of_represented`, `obsTyped_list_elements`, `obsTyped_chain_elements`). `IntegerFrame heap next` ("the next heap keeps every address, with its old contents or new integer contents") replaces the pair "flat next heap, size" in every frame lemma, with `integerFrame_after_write` and `integerFrame_after_allocation`; `allocated_frame` replaces `allocated_mono`. Eleven lemmas lost their heap premise. No statement of `flat_preserved`, of a case theorem or of `accepted_flat_anf_traces_agree` changed; no program is admitted or refused that was not before.
- The full `lake build` passed on the first run (101 jobs; 10743 constants, 4861 theorems; 4 depend on `sorryAx`, the pinned set; 68 files, 3 `sorry`, no banned token).
- COVERAGE's description of `FlatInvariant` and PROOF-PLAN's *Dictionaries* section (the 2a/2b split, an *As built* for 2a) follow.

**What I learned**

- Where a lemma took "the shape of a typed binding and a flat heap" to learn an array's contents, the shape can carry the contents itself: the typed expansion (`Represents.ref` with element observations typed `Int`) already fixes them. The relation then says nothing about arrays no binding holds, which is the room slice 2b needs for nested arrays.
- `lake exe ownership ci` runs the bridge self-test, and the bridge builds beni with `zorg build` from the repository root (`scripts/bridge.mjs`, `root`). A check of master in a plain export therefore needs the whole tree, not `proofs/ownership` alone.
- Since 2026-10-23 every heavy command goes through `heavy-run <timeout> nix develop --command …`, a two-slot semaphore with a memory wait; no `flock` or `systemd-run` by hand.
