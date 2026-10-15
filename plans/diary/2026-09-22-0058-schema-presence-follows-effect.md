## 2026-09-22 00:58 CEST — schema presence follows Effect

**What I did**

- Recorded the owner's acceptance of Effect's separate optionality and nullability
  model in the queue and report 32's supersession notice. Missing/null/value remain
  distinct unless an explicit transformation merges them. No implementation changed.

**What I learned**

- The convenient default is composable presence and nullability, not an automatic
  merge into `Nothing`. Beni's syntax and presence types still need specification;
  following these semantics does not require adding JavaScript `undefined`.
