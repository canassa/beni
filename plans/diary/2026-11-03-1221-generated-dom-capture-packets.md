## 2026-11-03 12:21 CET — Generated DOM capture packets

**What I did**

Added the manager-approved Context.packet bridge to the existing Any packet
producer, with checked identity tokens and strict freshness refusal. Added
black-box success and refusal cases, including a producer with no source pack
call. Added lazy-source and graph edges for the implicit Any dependency.
Grouped DOM inputs now use one capture tuple object tagged in place. Real
development and release DomPacket goldens retain the outer t/v node and show
no extra Box. The generic Html case retains its grouped patch.

**What I learned**

Codegen dependencies must participate in source discovery, graph pruning and
reachability. A runtime-module value lookup excludes foreign declarations,
so it cannot locate Any.pack. Grouped inputs also require checked reads inside
a larger expression, such as both model and delta in model.count + delta.

This is a reboot checkpoint. Full renderer migration, broad golden updates,
local identity-scope review, browser checks and performance comparisons are
unfinished. The new hardware policy requires two reproductions for merge
evidence; the current targeted successes are preliminary.
