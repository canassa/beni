## 2026-11-06 13:52 CET — A need nothing can discharge

**What I did.** Answered the five findings on #2134. A caller refuses a need whose code's result crosses a non-regular fold (`FoldCross`), no root but a parameter drops a step, a fixed function must answer fresh all through, a comparison and an entry refuse a need, the sanitiser note says a need rests on its callers, and §2.11.3's soundness argument is three exhaustive questions.

**What I learned.**

- My last entry said `LvlCb` was closed. It was closed for a `.cb` root alone. A short contract from #2062's parameter case became a short need by four more roads, and 77 generated variants showed it. Testing one probe of a family says nothing of the family.
- The general rule sits at the discharge, not the read-off: every need reaches a caller or is refused, and the caller's type is the concrete one, so one check there covers a polymorphic callee as well.
- `entryTea` is a real defect, confirmed in a page: the sanitiser traps at the second click, where in-place lists would make `get` answer the grown list. `EntryHeld` already had the shape.
- Widening the root rule costs 6 `Snd*` probes, SAME to REFUSED, and gains 11 DIFF to REFUSED. They are writes past a fold over fresh data, which §2.1 already lists as refused.
- I checked the spec's `need_watch` and `Deliver` item against the code only after the review did: they never existed. Rounds re-read the drafts, so the spec now says that.
