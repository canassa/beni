# Schema compiled workers: final evidence

Issue #1789. Typed record/tagged/recursive composition now passes the child value directly, with immutable parent paths and no Any Datum wrapper. The ownership rejection in the discarded Job draft was item:Datum at π6, not a path mutation; no checker waiver or copy patch was needed.

Dropping projections allows Direction to fix both endpoints. Removing redundant endpoint integers and impossible opacity preflight, plus a typed traversal sum preserving conversion/claim combinations, improves the bounded path without an endpoint generator. All44 Schema runtime fixtures and the final skill/API/ownership checks pass.

Verified one-shot6618047c0fcc2d79d9b6633830f8cc76 matches fresh Safe benchmark output. Aggregate release brotli falls17.0%, dynamic bundle49.4%, successful dynamic operations46–84%. Ordinary mixed compiled flat parse retains1.4–2.3% and print2.8–3.8% regressions; isolated/prebound protocols do not show a consistent worker slowdown. Raw protocols/IQRs are preserved; parity is not claimed.

Full gate remains red at the HostFree checkpoint, and final hash recording has the same29 failures as the preceding verified candidate. Baseline findings are preserved. One ownership diagnostic removes only its obsolete JavaScript fallback clause while retaining the shared-list rejection. A staged patch and manager handoff preserve this review point; no red commit or PR was made.
