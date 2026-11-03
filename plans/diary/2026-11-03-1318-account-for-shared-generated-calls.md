## 2026-11-03 13:18 CET — Account for shared generated calls

**What I did**

Investigated #1782 on workers-hostfree at cfc45f9792. Reproduced the release
panic twice, the second time with a fresh worktree-local Zig cache. Kept
Spec.checkScan unchanged and made call retraction/extension account for every
structural occurrence. A pending-call list now rewrites each node once, including
when its replacement is another call. Moved the checked-operand program into the
corpus and added a smaller forwarding-call project and toy lowering. Both
fixtures fail on the base twice and pass with the fix twice. Removing only the
pending-call guard prints leftright/leftright instead of rightleft/rightleft.

Compared actual output trees with saved base and fixed compilers: all 178
emit/release fixtures and all 697 run fixtures. Every previously successful build
is byte-identical. JsonDerivedModules is the sole difference: the base aborts in
checkScan → extend → inlineSmallAt, and the fix builds it successfully. Eight
release-shape fixtures and JsonDerivedDescribe have identical inherited build
failures. The independent comparison script and reports are saved under
~/worktree-evidence/wd-spec/ on dagon.

**What I learned**

Expression sharing is already supported: NameUse lists structural occurrences,
scalar replacement explicitly handles member nodes with two parents, and the
backend contract acknowledges shared call callees. The call delta was counting
one occurrence despite mutating all of them. Shared calls that remain calls also
expose a stale pending-body rewrite, which can silently reverse arguments twice.

The base's gates have substantial existing failures, including 133 of 178
release-shape goldens. The manager directed a comparison of actual outputs and
base/branch failure signatures, with no golden blessing; the hostfree owner owns
refreshing the inherited expectations.
