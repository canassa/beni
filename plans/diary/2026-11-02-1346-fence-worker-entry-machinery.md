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
