## 2026-10-21 20:15 CEST — put handlers at their DOM wiring

**What I did**

Implemented the handler-placement cut the owner ordered on 2026-10-19 (#625).
Each local DOM wiring and each piece-wire callback argument contains its key's
arm. Subscriptions and the command dispatcher retain named handlers. Every body
uses the same immutable, document-ordered pass for its key, computed after the
complete controlled-input union. Assignment, binding calls and commands keep
their existing order. Whole-message adapters and binding lifetimes stay intact.

The development-shape fixture fails against the repaired #619 compiler, which
shares a named handler between its two events. The candidate passes. Its matching
page exercises the two wirings in turn: 0 → 1 → 3 → 4. Both baseline and candidate
match in development and release. Focused checks covered pieces, whole messages,
controls, hidden captures and modifiers, dispatch, commands and subscriptions.
A self-audit caught a possible new handler closure during flagged dispatch;
ordinary mount-scope binding keeps it outside that listener in both development
and release, without optimizer pins or a runtime change.

One official measurement attempt on isolated #625, excluding #621, completed all
60 normal and exact compiler-constant-stub points: both scenarios, `--lists none`,
sizes 1/4/16/64/256, seeds 1/2/3. Brotli fits are fixed bytes plus bytes per widget:

| scenario | repaired #619 | #625 | validation, normal minus stub |
| --- | --- | --- | --- |
| unique-components | 2689.794 + 264.288458 N | 2749.085 + 256.730917 N | 644.187 + 19.349162 N |
| big-component | 2005.519 + 93.032468 N | 2055.230 + 91.080701 N | 422.683 + 9.716284 N |

The slopes improve by 7.558 and 1.952 bytes per widget, while fixed cost grows by
59.291 and 49.711 bytes. Small applications can grow: the N=1 medians change
1641 → 1640 and 1675 → 1681. Their tea-inline ratios are 1640/1337 = 1.22663× and
1681/1315 = 1.27833×. This is not an all-sizes saving or a byte-identity claim.
The frozen 1.1× cap remains unmet and unchanged; N=1 is reported, not a target.

The measured tree and compiler are preserved. Publication uses a fresh branch
on #621's clean parent, applying only #625's patch and fixtures; the PR records
its final combined-source qualification. The rejected #614 wrapper is excluded.

**What I learned**

`passOf` uses per-key stamps to deduplicate. Generating that key's arm again must
reuse the completed ordered slice: asking it again would omit later wirings'
binding calls. The repeated-key runtime fixture checks this independently of
its development shape.
