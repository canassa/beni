## 2026-11-13 15:26 CET — own3: rows at the entry, and what the default may ask

**What I did**

- Fixed the two faults of reader E (report 124), each as a whole rule.
  - **Locations (kernel §4.1, §6.13).** Two layouts' locations are compared only through the call map,
    in both directions (`locsMeet`), never by label path. The entry, the composition of answers and
    supplies, and a constructor's row used label paths; a row `{ r | n : Int }` read as "holds nothing".
  - **The default (§6.2, §6.8).** A function that a holder runs is handed the default at each function
    parameter (`defaultParams`): what it hands there escapes, and `Fn.rewrites` is refused. This holds
    at `top`, a lost holder, a partial application, a holder that calls it, the entry, and evidence
    (`Contract.Effect.rewrites`).
- The audit found six siblings, each trapping before. The adversarial review, in seven passes, found eight
  more, all one older hole: `Loc.cover` paired deep locations of two cycles by label path.
- Wrote research report 125 and revised kernel §4.1, §5, §6.2, §6.8 and §6.13.
- Gate results:
  - sweeps: 23 traps before, 0 after; 156 safe twins newly refused, 2 won;
  - sanitiser corpus: 0 traps before and after; 97 → 93 the same;
  - real writes: the same 287 of 308;
  - speed: 837k → 589k lines/s on v2's modules;
  - `zig build gates`: green.

**What I learned**

- A location of a deep level can stand for several places, and a type argument can make the caller's
  cycle larger than the signature's. No label path and no one sample path decides that. The sound rule
  reads one positive fact: does the signature have a variable or a row in that region?
- That rule is the whole speed loss. A sharper rule (an object under the variable's path) was unsound:
  the caller can enter its cycle above the variable. Winning the speed back needs a rule that decides by
  every place.
- Patching one branch of a relation at a time lost five review rounds. Asking "what positive fact decides
  this?" first would have reached the final rule sooner.
