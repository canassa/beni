## 2026-11-02 00:48 CET — Report standalone ownership DAG limit

**What I did**

Honored explicit ownership enforcement without requiring a platform chain and
added a complete standalone list-sharing diagnostic regression. The default
check remains accepted; explicit enforcement now refuses it. The regression
fails with the fix set aside and passes after restoration.

**What I learned**

The unchanged must-pass tuple DAG fails under the default selected checker:
1,276,786 summary entries against the 262,144 cap. Five declarations reproduce
it. Explicit ownership v2 passes. Per the delivery brief, the narrow branch is
pushed without a PR and the owner-decision finding is reported in
https://github.com/canassa/beni/issues/1640.
The original fixture, its assertion and the cap are unchanged; no full-gate
success is claimed for this intentionally unlanded branch.
