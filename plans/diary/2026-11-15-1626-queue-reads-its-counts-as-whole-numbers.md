## 2026-11-15 16:26 CET — Queue reads its counts as whole numbers

**What I did**

- Issue #1973, worker `queue-fractional-take`. I reproduced the defect on master `e72a8bfd80` with a `foreign half : Int` of `0.5`, as `run/CoreListFractionalCount` does. `Queue.takeN q 1.5` moved the queue's start to `1.5`, so `size` was `1.5` and `poll` answered `Just undefined` twice. `dropping 1.5` held two values. `takeN q 2.5` took three values. `dropping` of NaN was never full, and `bounded` of NaN let a waiting offer in at once.
- `core/Queue.beni` now reads each count once with a private `whole`, the rule of `language.md` §6.8 (*An index or a count that is not a whole number*): a fraction is cut toward zero, and NaN or a count below 1 is 0. `takeN` uses it for `n`, and `make` uses it for the capacity of `bounded`, `dropping` and `sliding`, where a capacity below 1 stays 1. The doc comments give the rule.
- `language.md` §6.8 has an amendment that names `core/Queue`.
- The fixture is `run/QueueFractionalCount`. With master's `core/Queue.beni` it gives 22 wrong lines and stops in a deadlock. With the fix it passes.

**What I learned**

- A fraction in `start` is worse than a wrong count: every later read of `items[start]` is `undefined` under a type that says `a`. One cut at the entry keeps `start`, `need` and `cap` whole, so no loop needs a change.
- A NaN `takeN` on a queue that is not ended waits for ever on master (`count ≥ NaN` is never true). The fixture asks it on an ended queue, so master fails with a wrong answer and not with the hang guard.
- Inside `Io.run`, `Node.print` is a `Program` and not a statement. The Queue fixtures print with `Debug.log` and end with `Node.print "done"`.
