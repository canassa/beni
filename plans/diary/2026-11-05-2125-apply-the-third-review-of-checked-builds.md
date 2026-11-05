## 2026-11-05 21:25 CET — Apply the third review of checked builds (#1999)

**What I did**
- Applied F1–F14 of the third review, with the owner's two decisions. `language.md` gained §13.11 (a value is not generic over what it computes) and a definition of "stops" per platform in §13.6, and `checker-v2.md` §8.4 and `transparent-effects-proposal.md` §17.5 are amended to match. `boundary.md` §4.2 declares `Js.checked`, `Js.cast` and `Js.peek`. `backend.md` §16 makes evidence a function of the scheme alone, and step 2 of the order of work gains the predicate sweep. `language.md` §6 now says emission order is part of the checked contract.
- Opened #2077–#2080 and added the scheduler path to #1994. Report 111 gained §9. Merged master. Added new commits only.

**What I learned**
- D1's wording, "every declaration receives evidence", passed two reviews because declarations were all anyone read. A `let` value is not a declaration and has no parameter. A rule about where something goes must ask what has no such place.
- `number` being a kind and not a wanted is why the value restriction missed it: the restriction's own reason, "a value would become a function", applied word for word.
- "A read that goes past the end tests the length itself" was a statement about the tree, and I wrote it without looking. A logging prototype, a few lines of code, found thousands of counterexamples. A claim about all sites needs a sweep, not a sentence.
- A rule that depends on a body makes an ABI depend on a body. Any fact in an interface has to come from the scheme.
- "First use fixes it" at top level had to become "defaults when its group closes": a group is checked before its users, and declaration order may not change what checks.
