## 2026-11-01 23:28 CET — Own JsIr transfers on error

**What I did**

Kept a temporary error-path owner for each detached JsIr column until every
fallible transfer succeeds. Added an allocation-failure sweep of the public
Builder operation with nonempty nodes, extra words, strings and names.

**What I learned**

The same sweep leaks on master with the cleanup fix stashed. Disabling resize
in the test makes shrinking transfers allocate predictably, following the
existing InternPool allocation test. This allocator boundary needs no CLI hook.
