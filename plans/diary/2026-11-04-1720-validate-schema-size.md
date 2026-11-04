## 2026-11-04 17:20 CET — Validate schema release size recovery

**What I did**

Validated the partial #1859 fix after dagon's disk all-clear. Existing emit
outputs recover 1,640 brotli bytes, with ValidatorRun 841 → 737. Only the three
existing goldens whose base output matched the committed snapshot are refreshed;
inherited drift remains red. Added executable and shape fixtures for Number
predicates, held-sentinel guards and array lengths, and regenerated the API
reference. Native byte-exact checks pass. The final full gate run has zero added
failures against the saved base (160 failing corpus cases → 159).

**What I learned**

Two paired CPU8 benchmark runs measure specialised flat parsing +2.4%/+1.3%,
missing-key parsing +4.2%/+1.6%, and flat printing −0.4%/−0.5%. The owner judged
the parse deltas noise and instructed the lane to proceed without isolation.
#1814 remains open for final integration measurement; generic optional payload
specialisation is deferred to #1865. Per-golden sizes, per-operation medians and
validation details are in plans/schema-size-evidence.md.
