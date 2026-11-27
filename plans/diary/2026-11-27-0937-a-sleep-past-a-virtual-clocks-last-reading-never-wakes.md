## 2026-11-27 09:37 CET — A sleep past a virtual clock's last reading never wakes

**What I did.** Built the sixth and last clock site of #2022: a sleep on a virtual clock whose
wake time is past 9007199254740991, the last millisecond an `Int` holds. The answer to the
dashboard question `clock-int-range-q1` is "It never wakes" (Jayson, 2026-11-25).
`transparent-effects-proposal.md` §17.6 states it in place of the bullet that called the site
open, §17.7 says what it means for `timeout`, and §17.8 for the delay that `retry` and `repeat`
sleep. `virtualSleep` in `core/Task.beni` now tests before it adds, with the test of
`adjustClock`, and does not put such a wait among the sleepers. The fixture
`run/VirtualClockSleepPastEnd` pins it. The first five sites were merged two days before, so this
work is a second pull request from a new branch.

**What I learned.** The fix of one site can make the defect of the next one impossible to see.
Since `Clock.adjust` refuses each move past the last reading, a sleeper with a later wake time is
never due, with or without this change. The fixture is green on the master before this change and
red only on the core from before `adjust` answered a `Result`, where the sleeper woke at
9007199254740992. So "fails before the fix" is true for the issue and not for this commit, and the
pull request says so. `beni build --core-root=<dir>` with a `git archive` of an old commit runs a
fixture on that commit's core with today's compiler, which gave the proof in a minute. A
correction of the entry of 2026-11-24: its "sixth waits for the owner" is done now. A branch made
with `git switch -c <name> origin/master` tracks `origin/master`; I removed that upstream before
the first push.
