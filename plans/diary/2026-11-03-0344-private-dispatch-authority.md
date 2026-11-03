## 2026-11-03 03:44 CET — Private dispatch authority

**What I did**

Fixed #1749 against workers. Named resolution and imported static dispatch
share one CorePrivate access predicate and diagnostic explanation. The checker
carries effective core/platform/app authority, including root sources under
`--core`. Runtime, core, Task, worker, platform and Debug policies retain
their package and caller identity restrictions. A refused bridge also poisons
its unresolved result so a chained socket call reports its private method
without an unrelated unknown-receiver error.

Black-box coverage exercises all rule kinds, the Cloudflare socket chain,
legitimate platform/core callers, spoofed Task/Debug modules, and cache
isolation between ordinary and core-authoring checks. The regression fails
on the earlier compiler because the private call is accepted; it passes with
the shared rule. Cloudflare migration remains parked while wd-size fixes
replyScan's missing artifact during embedded platform library generation.

**What I learned**

A private nominal type need not be named by an app to become a dispatch
receiver: a platform can return it through a public value. Therefore the
privacy decision belongs before imported method instantiation, using caller
authority rather than the receiver's trust or the caller's spelling.
