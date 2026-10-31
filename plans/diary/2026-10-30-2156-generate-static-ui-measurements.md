## 2026-10-30 21:56 CET — Generate static UI measurements

**What I did**

Specified and added an internal dynamic-import expression to JsIr, retaining
its operand and module-evaluation effects through verification, optimization,
copying, traversal and both printers. Added a Zig-generated static UI driver
using the existing benchmark helpers without editing application JavaScript.
It validates every counter synchronously after each timing sample and records
mount and dispatch throttling separately.

**What I learned**

Node syntax checking does not detect an accidentally escaped import identifier;
the manager also executed the generated import and checked its known export.
The generated evaluator tests reject delayed rendering and missing counters in
all four measurement paths. Manager Debug generation, execution and focused IR
tests passed. This is measurement plumbing, not a UI parity result. Actual UI
measurements remain pending the existing scalar-class and keyed-renderer gaps.
