## 2026-11-15 17:17 CET — Int.mod, Random.int and Duration stay in range (#1992)

**What I did**

- Reproduced the three defects of #1992 on master `e72a8bfd80`: `Int.mod` near 2⁵³ was one off, `Random.int 0 4294967296` looped for ever, and `Duration.seconds`, `minutes`, `hours` and `sum` went past 2⁵³ − 1 ms.
- `Int.mod` adds the modulus only to a remainder of the other sign, and gives `0` for a zero remainder.
- `Random.int` keeps its 32-bit path for a range of at most 2³² integers, so a seed gives the same values as before. A wider range uses 53 bits from two outputs with rejection. A range of 2⁵³ integers or more uses one more bit and draws again past `hi`. No intermediate value leaves the `Int` range.
- `Duration` tests its operands before it multiplies, adds or rounds, and saturates at the longest duration.
- Three `run/` fixtures. Each fails with master's `core/` (`--core-root`) and passes with the fix.
- The browser-inline write-set pass now folds `//` on constant integers, as `Basics.idiv` answers it. Without it, `Time.seconds 1` in a subscription was no longer a constant key.

**What I learned**

- A change to `core/` changes the `fingerprint` of every dedicated worker in the `emit/` goldens. Bless them with `BENI_WRITE_EXPECTED=1 BENI_BLESS_ONLY=dedicated/` and check that only the fingerprint strings changed.
- The write-set pass reads `Duration`'s body to make subscription keys. A new operator in `Duration` must be one that its constant folder knows.
- `git archive origin/master core` and `beni build --core-root=` prove a core fix fails before, with no stash and no second build.
