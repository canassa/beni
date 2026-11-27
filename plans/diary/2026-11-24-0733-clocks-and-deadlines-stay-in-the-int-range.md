## 2026-11-24 07:33 CET — Clocks and deadlines stay in the Int range

**What I did.** Gave five of the six clock and deadline sites of #2022 a written answer and built
them, on the owner's decision of 2026-11-05 (#1988): a typed failure for an unrepresentable
deadline supplied from outside, and saturation only where it is promised. The sixth, a sleep on a
virtual clock whose wake time is past the last `Int`, waits for the owner (dashboard
`clock-int-range-q1`). `Clock.adjust` and the cloudflare
platform's `Object.alarmIn` answer a `Result` now (`Err TooFar` when the time is past
9007199254740991), and a failed call changes nothing. `Schedule.fixed`, the `elapsed` that `retry`
and `repeat` give a schedule, and a log span's milliseconds use `Duration`'s saturation. The
contract is in `transparent-effects-proposal.md` §17.6, §17.8 and §17.11 and in `boundary.md`
§9.12 (e.5). Five fixtures fail on master and pass now: `run/VirtualClockAdjustTooFar`,
`run/ScheduleFixedLongest`, `run/RepeatElapsedLongest`, `run/LogSpanLongest` and
`workers/ObjectAlarmTooFar`. 26 statement calls of `Clock.adjust` became `_ = Clock.adjust …`.

**What I learned.** The issue names sums, but a difference of two readings leaves the range too:
a virtual clock reads a negative `Int`, so `now − began` can be more than 2⁵³ − 1. A guard of the
form `d > L − now` overflows itself for a negative `now`, so the sign is tested first. A fixture
for `Schedule.fixed` needed hand-made metadata with an `elapsed` before the first step's: only
there is the wrong number visible. `alarmIn` read the host's `Date.now()` from its first commit
while `boundary.md` said `Clock.now ⊤`; the host alarm fires on the host's clock, so the document
was wrong. A new `run/` fixture that keeps a list in a `Ref`, or pushes onto a list parameter,
fails the v1/v2 ownership parity check; write it without them. A doc comment line of the form
`expr == value` in `core/` is compiled as an assertion by `docs_test`.
