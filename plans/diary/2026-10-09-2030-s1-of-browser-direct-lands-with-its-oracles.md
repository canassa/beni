## 2026-10-09 20:30 CEST — S1 of browser-direct lands, with its oracles

**What I did** (as manager)
- Correction to my previous entry: its heading says 05:40; it was written at 13:52 CEST.
- S0 and the stats gate merged. The gate's four fires were brought to the owner: tag reads
  (merged, with an asserted invariant) cut Conduit's checks per key from 9.2 to 7.2; the routing
  split and the page frame are planned (timing to be confirmed); the trie is set aside.
- The page fuzzer is merged after a review that found eight ways it could pass falsely. It now
  compares title, location, storage, logs and control state, and it is proven by breaking a text
  value, an attribute, a `.value`, a keyed list and the title.
- S1 is merged. Holes, per-key handlers, direct listeners, the `*` key, the verify mode (now
  reading the DOM) and `--fuzz` on both platforms. Kill criterion 3's bytes first fired (36 kB);
  the owner widened baking (Track K), and the holes page is 575/609/615 B at 10/1 000/10 000,
  holes 10 000 1.09× vanilla. The review found a form-feed attribute bug, fixed red-first in
  happy-dom and Chrome.
- A dashboard artifact compares vanilla, Solid 1, beni old and beni new on speed and bytes.

**What I learned**
- A green oracle can be a vacuous one: the fuzzer first compared only the body and requests.
  Proof tests that break each kind of write are what make it trustworthy.
- Fuzzing every page with values multiplied builds past the budget. Scoping it to what the
  design requires, by name and with the reason printed, kept the rule without hiding coverage.
- "Output unchanged" needs checking at the right level: the JavaScript was identical, and only
  source maps moved, which is what changed 137 run hashes.
