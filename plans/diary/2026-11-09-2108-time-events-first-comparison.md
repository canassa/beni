## 2026-11-09 21:08 CET — Time/events first comparison

**What I did**

Moved Cmd/Sub/Hosted/Time/Browser.Events to the renderer-free base and built scoped inline waiting work, command/update log-context boundaries, and the approved staged prerender init proof. Added red-before capabilities fixtures and focused stop/defect cleanup, context, static interval, named/batch init and eager-host-read checks. Generated API references and updated skill limits. Preserved local-only work, no GitHub actions or family commit.

Compared first snapshot gates and Chrome against clean master on zorg.3/default mode, sequentially under the manager slot. Recorded all 59 emit diffs and release sizes in zig-out/scratch/time-emit-review.md, exact failures and sizes in time-family-report.md. No golden was regenerated during the comparison. Removed the master comparison build cache after its runs; minimum free space stayed above 7 GB. Released the slot.

**What I learned**

Static Time.every intervals now survive Duration clamp/conversion analysis and equivalent intervals share timers. Cancelled fibers must keep scheduler turns to finish finalizers after stop. Moving opaque Hosted send boundaries also requires moving the ownership checker's asserted-row package selection; TaskWords mutations exposed that omission and all targeted word checks pass after repair. The comparison found missing Hosted reexports, a moved-path fuzzer target, and unnecessary update IIFEs even where context is eliminated. These defects must be fixed before a commit. Ten new ownership summaries change representation while preserving every verdict line. TodoMVC remains not measurable without inline Dom/Storage; empty CSR is identical, while empty prerender has +5 raw/-1 Brotli from helper specialization. No release record-field evaluation-order defect was encountered.
