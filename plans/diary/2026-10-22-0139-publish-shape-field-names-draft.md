## 2026-10-22 01:39 CEST — Publish shape field names draft

**What I did**

The owner requested an MR after the #658 validation blocker was reported.
Prepared the existing #653 work as a draft PR, explicitly recording that the
green-gate requirement cannot yet be met. Kept the host-boundary reproducer.
Moved the stale golden from the earlier, smaller fixture into zig-out: it
must not be presented as the expected output for the extended fixture.
The final release golden, existing affected goldens, run hashes and full
gates remain outstanding after #658 is fixed. No new builds or measurements.

**What I learned**

The draft makes the owner-approved contract amendment and implementation
reviewable while keeping the known baseline compiler failure visible.
