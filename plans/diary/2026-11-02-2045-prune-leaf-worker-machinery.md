## Prune child and absent event machinery from workers

**What I did**

Separated child abandonment from leaf-worker shutdown through a hook installed
by child launch. Added per-entry event capability facts from the Wire graph's
finite inhabitants, emitted in constructor object literals and attached without
losing identity or primitive boxing. A worker-only allocation-type fold removes
the release representation guard. Added black-box coverage for empty records,
recursive empty types, inhabited lists/recursive variants, unresolved event
roles, identity preservation for object/function Programs, malformed EventAck rejection,
and a platform's boxed primitive Program.

**What I learned**

A late metadata write joins the field's initially absent value in the may-analysis;
the fact must start in the allocation. Bottom is recursively encoded, so counting
constructors does not establish inhabitance. The child hook alone saves 317 bytes
brotli on the measured worker; removing absent event bookkeeping increases that
saving to 411 bytes on top of clone-stable Wire pruning. Ordinary no-worker output stays the same.
