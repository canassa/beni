## 2026-10-17 01:12 CEST — A value of a type variable may hold a list of it

**What I did.** Issue #270. `mayHold`, §6.1's type filter for what a value may hold, answered "no" when a
type variable `a` occurs below the other type (`List a`). With `type Tree = Node (List Tree) | Leaf`, a
callback `List a → a` may answer `Node xs`, so `t = f xs; List.push xs t` put `xs` inside itself, and the
checker accepted it `param`. `mayHold` no longer takes the shortcut; `mayShare` keeps it, as the issue
decides. Spec: a dated amendment to §30.9 rule 4. Fixture `ownership/RecursiveHolds`, red with master's
binary; a push onto `List.copy xs` stays accepted. One summary in `BridgeResultPaths` keeps an alias it
dropped before; no verdict moves. `bench/ownership-everywhere.mjs`: 0 of 850 programs rejected.

**What I learned.** I probed `mayShare`'s shortcut too, with a type of one constructor and one field (which
the checker counts as unboxed): a generic `( List.push (g t) t, t )` makes a cycle and master accepts it.
The cause was not `mayShare` but #216's class (an unknown callee's result taken as made by the call), and
#225's head rejects every probe. A probe that seems to show a second hole needs the fix of the first hole
in place before it says anything.
