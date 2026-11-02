## 2026-11-02 02:20 CET — Normalize imported worker Programs

**What I did**

Passed the Program's declaring module into wire-plan lowering, so descriptors
opened from another module retain their parameter normalization plans. Added
Chrome pages for an imported Program receiving a List rest view and a worker
opening another module's Program with the same request.

**What I learned**

Both pages reproduce an uncaught DataCloneError before the fix. The descriptor
carries the correct wire artifact already; the parameter lookup lost its module
identity by using the opening module. Nested worker launches hit the same lookup.

The nested page forwards the child's reply through the test transport's existing
reply primitive, now public on that test platform. A first version waiting in a
suspending handler exposed a separate transport effect problem, recorded in
#1660; this regression needs no suspension.
