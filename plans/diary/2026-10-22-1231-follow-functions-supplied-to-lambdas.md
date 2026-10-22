## 2026-10-22 12:31 CEST — Follow functions supplied to lambdas

**What I did**

Reduced #223's fold refusal to a page fixture and confirmed it red before the
change. A lambda's own function-parameter result now stays symbolic in its
class and follows the consumer's supplies. Calls retain borrowed argument
provenances, and result identities include their frame. Local writes onto
unresolved results remain refused. The page now renders its expected value;
negative twins retain refusals for shared and borrowed validator results.

Compared every existing ownership golden: no verdict changed. One existing
summary becomes more precise about a retained input. FormValidation falls
from six refused list demands to five; its recursive returned-validator
class is the separate remaining cause. Added the dated contract amendment.

**What I learned**

A call instruction cannot identify a callback result alone: it can also be
the instantiation site of an enclosing callback. Scope must be part of the
cell's key. The known send parameter must keep its transfer protocol rather
than entering the unknown function-parameter path. Existing soundness
fixtures caught both candidate mistakes; none was pushed or blessed.
