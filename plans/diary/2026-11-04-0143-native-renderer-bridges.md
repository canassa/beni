## 2026-11-04 01:43 CET — Private native DOM renderer bridges

**What I did**

Added 13 renderer-prefixed Node, Document and EventTarget adapters for typed native DOM handles. Wrote the approved private bridge contract first, fenced application names and methods, and retained the existing Element identity upcast and public append API. Saturated calls lower directly; first-class values share compiler-emitted arrows and the existing Opt sentinel. No Js.js change, second sentinel, per-call wrapper, Result or catch.

Added dev/release emit, happy-dom, Chrome, application-refusal and ownership fixtures. Native generation is byte-exact, with the upcast's declaration source checked. Rebased onto d853ad81e3. Full gates on base/after have 1119 green unit tests and the same 27 inherited test failures and 254 failing fixture paths. Fixed the added generator import-formatting issue after that run; focused formatter checks now match the same 24 inherited paths. Ownership inventory/pin checks pass for the additions. Retained 192 attributable verified run records after exact-base full recordings; restored inherited-only drift.

The ordinary mounted page's complete development and release output trees are byte-identical; release is 1670 raw and 792 brotli bytes. Worker DirectWire stays 52685 raw; brotli changes 14113 to 14119 (+6), solely from the source-graph fingerprint. The worker measurement uses its existing corpus launch-guard override; the ordinary page uses ordinary flags. Evidence and scripts: ~/worktree-evidence/wd-dom-native/. Tracking: #1822, Part of #1612.

**What I learned**

An identity upcast needs the declaration-source path in both native validation and binding metadata; scanning an empty member can otherwise hang. Nullable native adapters must share the compiler-owned Opt sentinel, including through first-class values and reachability. Direct recipes must evaluate discarded unit arguments and pin operands before repeated reads; the regression was red before that fix. Generated import groups must match the formatter, as well as the generator's byte-exact check.
