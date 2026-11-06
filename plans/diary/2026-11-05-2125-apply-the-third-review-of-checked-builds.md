## 2026-11-05 21:25 CET — Apply the third review of checked builds (#1999)

**What I did**
- Applied F1–F14 of the third review. The owner reopened F1 while I worked, so I took its first text out in a commit, and wrote it again after the decision on research 112: a value that computes at `number` is held, a top-level one defaults to `Int` in its own group, and D1 goes on the wanted path, read from the scheme, narrowed to `+ - *` (`language.md` §13.10, §13.11, `backend.md` §16.3, `checker-v2.md` §8.4). Both are in the history, as the owner asked. `language.md` gained a definition of "stops" per platform in §13.6, and `transparent-effects-proposal.md` §17.5 is amended to match. `boundary.md` §4.2 declares `Js.checked`, `Js.cast` and `Js.peek`. `backend.md` §16 makes evidence a function of the scheme alone, and step 2 of the order of work gains the predicate sweep. `language.md` §6 now says emission order is part of the checked contract.
- Opened #2077–#2080 and #2086, and added the scheduler path to #1994. Report 111 gained §9, and research 112 joined the PR as written. Merged master. Added new commits only.
- Traced the two gate failures, `ChildProcessRun` and `ChildProcessCancelled`, on plain master: the harness's child has no `PATH`, and NixOS's `/bin/sh` defaults to `/no-such-path`, so `sleep` is not found (#2086). I blessed nothing.

**What I learned**
- D1's wording, "every declaration receives evidence", passed two reviews because declarations were all anyone read. A `let` value is not a declaration and has no parameter. A rule about where something goes must ask what has no such place.
- "Decided" can reverse while the work is in flight. I had written option (a), with "first use fixes it", and the research showed why that fails at top level: a use must not change a declaration's type. A hold that keeps the commits and adds a removal costs little; pushing the first text would have cost more.
- Two statements can each be right and still meet oddly: "the ABI is read from the scheme" and "`abs` needs no discriminator". I reconciled them with a fixed list in the operator table that reads no body, and I flagged that in the PR for a second look.
- "A read that goes past the end tests the length itself" was a statement about the tree, and I wrote it without looking. A logging prototype, a few lines of code, found thousands of counterexamples. A claim about all sites needs a sweep, not a sentence.
- A rule that depends on a body makes an ABI depend on a body. Any fact in an interface has to come from the scheme.
