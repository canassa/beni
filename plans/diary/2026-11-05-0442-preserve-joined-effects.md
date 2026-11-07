# Preserve discarded effects at suspension joins

Confirmed #1951 on current master 006f4a9e75: SuspendJoinEffect prints `1 5` in development but silently prints `1 1` in release. A loop join substitutes `return join(value)` with a new const binding. When the rest ignores the value, the binding can disappear unless it carries Lower's effect-retention mark.

Mark generated non-literal joined-value bindings conservatively. Literal/identifier/arrow values remain eligible for ordinary elimination, and the existing clone path already preserves marked const bindings. No protocol rewrite or runtime change is ported from workers.

The run fixture covers a straight-line conditional and a tail-recursive loop with a conditional Ref.set and yield. Its release output is red before and green after. Three precise parity rows describe existing checker behavior: v1 crosses primitive Int cell contents; v2 reports the same safe writes as accepted, including through recursion. The checker and publication rules are unchanged.

Full master gates pass without changing existing emit goldens. Workers and real Chrome validation logs, exact base/compiler and the red output are preserved under ~/worktree-evidence/wd-fiber/master-1951/. Work lands through a small PR into master; the manager merges it.
