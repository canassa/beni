## 2026-11-01 12:48 CET — fold certificate part A: proof, publication, checks

**What I did.** Part A of #1485 on `own2-fold-cert-a`, over #1529. The stop rule's
post-fixpoint discharges the certificate's induction (an amendment marked for review in §8
slice 4, *As built, part 2*), checked again under `runtime_safety` (C5). The block (version 15)
carries the certified mark and each position's fold obligation. `certRead` now reads the
class's κ at `K`. C1, C3, C4, C5 and C7 are `runtime_safety` checks, each with a mutation
that makes it fire. New fixtures: `o/FoldCertificateImported` and `o/FoldedKnotCall`. Ran an
oracle sweep of 31 programs (25 376 runs, 0 unsafe; UNSAFE when every verdict is forced to
accepted). Opened #1533 for row 14.

**What I learned.** A certificate published as a mark alone was unsound across a block. The
repeat of `unroll` lived only in the producer's `fold_cond`, which the block merged into the κ,
so `incRoot (Lib.unroll t)` was accepted. The certificate's keys are a set, so a multiplicity of
2+ is only in the class's κ, and any reader of the keys alone takes it as once. That is why row 2
(`dupL`) had accepted lines: it was not the `xreq` case. A check that walks a member over ports at
⊥ moves the records of later walks in the module, so a check is not free of side effects even
on a scratch account.
