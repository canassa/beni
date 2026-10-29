## 2026-10-30 00:26 CET — the reply walk over a work list

**What I did.** The two rounds of #1255's review on the `cloudflare` siblings' move. Round 1: the
walk that finds the replies a message holds, written as a recursive beni function with three
arguments and two locals, fell at about 4 050 levels where master's one-argument closure walked
4 640; it runs over a work list now, and `workers/ObjectDeep` posts a value of a recursive type
nested 5 000 deep to itself — a defect and `depth 0` on the old compiler, `depth 5000` on the
head. Round 2: pushing a container's children in reverse with `slice` and `reverse` copied each
twice and made the walk about twice as slow as master's on a small record; it is a backward index
loop now, as `core/Task`'s `pushBack`, timed with the reviewer's probe against master. Also the
dates, read from `date` from now on, and the harness gap of issue #1263 (a `workers/` fixture
cannot inject a host fault).

**What I learned.** A recursive walk written in beni costs more stack per level than the
JavaScript closure it replaces — three arguments and the locals of each level — so a move that
keeps the recursion keeps less depth; a work list keeps none. And a work list is cheap only
when nothing is copied to feed it: the first version paid twice per container, which the
reviewer's probe showed and the index loop removes. Every date in a spec comes from `date`.
