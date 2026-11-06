## 2026-11-06 04:38 CET — drop the parentheses that held only a class

**What I did**

- #1645: `tests/skill_api.zig` removed each effect class from a dump line but kept the
  parentheses that the dump writes only to hold one. So `skills/beni/references/api-*.md`
  showed `→ (Cmd msg)`, `(Generator a), …` and `((Send msg) → ⊤)`.
- Now the generator also removes those parentheses. A type then reads as a diagnostic prints
  it. The rule comes from `src/check/Render.zig`'s `write`:
  - A nominal type with a class is in parentheses everywhere except at the top. Without the
    class, it needs them only as an argument of an application, with arguments of its own
    (`List (Cmd msg)`).
  - A function-typed result is in parentheses only when its arrow has a class. `→` is
    right-associative in its result, so `→ (⊤ → ⊤)` becomes `→ ⊤ → ⊤`. A function in every
    other position keeps them.
- Amended `frontend.md` §12.1 first, then regenerated `api-browser`, `api-browser-inline`,
  `api-core` and `api-node`.
- #1651: reproduced on master. `1 / -0` prints `Infinity` in development (`1 / (0 - 0)`) and
  in `--release` (`1/0`). Asked the owner (`small-fixes-q1`) how to fix it. The fix touches the
  `0 - n` contract of `backend.md` and the owner's open PR #1292.

**What I learned**

- The dump already prints a function result with no parentheses when the outer arrow has no
  class: `Parser (a → b → r) r`. Only a class on the outer arrow adds them.
- `beni fmt` keeps redundant type parentheses as written, so both forms are valid beni. The
  generated files now match the diagnostics' form.
- `-0` is not a literal token. The parser reads it as prefix negation, BIR lowers it to a call
  of `Basics.negate`, and `Lower` writes `0 - n`, which `backend.md` and
  `run/OperatorsInPlace` pin on purpose. PR #1292 changes that contract and is open with
  conflicts since 2026-10-30.
