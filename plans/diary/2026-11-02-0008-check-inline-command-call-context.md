## 2026-11-02 00:08 CET — Check Inline command call context

**What I did**

Kept the imported callback effect join and corrected Inline's conservative
poly rejection. A polymorphic command is evaluated with its actual synchronous
sender and captured values through the existing value evaluator. Unknown calls
and exhausted analysis remain refused. Direct update inlining now permits a
twin for returned closures when both the caller and selected update are direct.
Added synchronous and captured-yielding generic-command corpus cases.

**What I learned**

Preserving the join makes latent command effects visible. Eight existing pages
were falsely refused by the old blanket poly guard; the deep-key page also hit
the old blanket update-twin guard. Both are implementation precision defects,
not reasons to weaken those pages or discard the callback's effect relationship.
