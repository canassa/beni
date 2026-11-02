## Typed cell and optional-slot review fixes

**What I did**

Made Cell and Ref allocation impure so module-level mutable storage cannot
quantify its contents. Gave the private Int32 schema descriptor concrete
endpoints, as the Char descriptor already had. Closed Js intrinsic dot-call
dispatch and exercised the application fence without importing Js.

Replaced undefined absence with the owner's one private core sentinel.
Unit and Js.Value payloads are admitted; direct nesting remains refused,
including through imported generics. Added a host that returns no unit value,
generic remember, cross-module absence and cache checks. Strengthened the
fixed-shape golden and added shared-callback and crossing witnesses; all
three requested implementation reversions now change their fixtures.

**What I learned**

Purity is part of the top-level value-restriction argument: mutable identity
factories cannot claim pure even when the allocation itself can be discarded.
An undefined hole does not cover foreign unit results. A private shared
sentinel does, while release must still preserve wrappers around empty Opt.
The repeated Link micro case remains about 112 -> 56 retained bytes per node.
