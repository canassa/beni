## 2026-11-02 00:48 CET — Honor standalone ownership enforcement

**What I did**

Honored explicit ownership enforcement without requiring a platform chain and
added a standalone list-sharing diagnostic regression. The default check stays
accepted; explicit enforcement now refuses it. With enforcement on, the tuple
DAG fixture `OwnershipAnnotationDag` exceeds v1's summary limit
(1,276,786 entries against 262,144; v1's #856), while v2 passes. Per the
decision on #1640 the v1 expectation is the pending scenario CK-316 and the
gated test runs v2. The cap is unchanged. The branch lands as a pull request
(#1509, #1640) and the gates pass.

**What I learned**

The old must-pass test passed only because the flag was ignored without a
chain.
