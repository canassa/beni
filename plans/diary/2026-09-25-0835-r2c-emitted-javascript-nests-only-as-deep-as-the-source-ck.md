## 2026-09-25 — R2c: emitted JavaScript nests only as deep as the source (CK-83)

**What I did**

- CK-83 closed: accepted programs lowered to JavaScript nested past what engines parse (a
  ~1 700-element list, long `++` chains, ~2 000 nested calls), so `build` exited 0 and Node threw.
  The implementer measured six engines from nix (headless Chrome 153, Firefox 144, WebKit, Node,
  the SpiderMonkey shell, Bun) and specified bounded shapes first in `backend.md` §4: long lists
  as one array folded into cells, flat `&&`/`||` (including operands that need statements), deep
  subexpressions and closures bound to `const`s in the hoisting list, flat `else if` chains.
  Budgets sit at least 2.5× under the scarcest browser; source nesting past them (about 120
  nested functions, a view about 65 levels of `List.map` deep) is `nesting_too_deep`, naming the
  declaration.
- The review caught two refusals of programs that built before and load in every browser: a
  TEA-style `view` with a `List.map` per level was refused at 20 levels (lambda bodies did not
  count toward their parent's height), and a 140-term `&&` of statement operands. Both fixed,
  with fixtures checked in Chrome, Firefox and WebKit.
- Evaluation order unchanged across about 60 generated probes against 7ae452f. No existing golden
  moved; emit ≈ +1 %; output size unchanged after brotli.
- New: CK-87 (derived `==` past 32 nested record levels is `internal`) → R8a; CK-88 (a `case` of
  many literal branches emits in O(n²), and past 65 046 a `switch` SpiderMonkey refuses) → R12.
- Gates green; `test-pending` 69 + `test-pending-perf` 8 RED, 0 GREEN.

**What I learned**

- For a browser-first language the refusal thresholds are a product decision, not a detail: the
  first version refused ordinary UI code. Test a new limit against the code users will actually
  write (a generated `view`), not only against the synthetic extreme.
