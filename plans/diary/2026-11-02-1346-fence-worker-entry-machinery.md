## Fence worker entry machinery and preserve defect causes

**What I did**

Fenced engine-only worker entry functions at imports and static dispatch,
including application modules that spoof a runtime module name (#1678).
Checks share build reachability for the unchecked launch gate and its bypass.
Preserved the platform's Task.onDefect hook, made optional stop callbacks safe,
reported close deadlines as ConnectionLost and retained worker Error names
(#1682). Kept peer storage unchanged for the concurrent HostFree migration.

**What I learned**

Import privacy alone misses a nominal type's methods: worker.run also needs
the checker fence. A layered platform can supply a different Program type and
have no page-stop bridge, so the native error path must retain the original
defect and the platform's own hook. Regressions fail with the fixes stashed.

**Review correction**

The first hook fix made any native page error initiate shutdown and missed
worker realms. Added Task.chainDefect to preserve the platform hook while
running worker shutdown in the fiber-defect path in both realms. Native error
listeners now only attach metadata to an already-started beni stop. Chrome
fixtures distinguish a third-party timer error from a nested-worker defect,
checking that the page still handles messages in the first case, and that a
nested child receives Close and runs its root finalizer in the second.
The nested fixture parks a user finalizer so ordinary scope cleanup cannot
satisfy its assertion: the shutdown hook must send Close before it completes.
