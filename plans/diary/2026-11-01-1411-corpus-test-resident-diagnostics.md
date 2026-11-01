## 2026-11-01 14:11 UTC — Corpus-test resident diagnostics

### What I did

Added a source-on-disk corpus regression for #1539 through an external driver importing the ordinary public beni.Session module. Watch/serve and check/build create fresh Sessions, so a normal CLI repair sequence cannot expose the resident library defect. The driver uses existing Session, SourceStore, cache and profile APIs only; it neither inspects workers nor resets diagnostics. Its registered blackbox case compares every rendered ordinary message/span and Summary count against the corpus golden, at jobs1 and8. No compiler CLI feature, language rule or production behavior changed beyond the already-frozen2f3 fix.

The identical driver, fixture and registered test ELF fail before the fix and pass after. The separate owned before source snapshot changes only the four-line run-start borrowed-aggregate/worker diagnostic cleanup block (including its comment). Before output is warning1, cached warning2, error1+warning2, then repair still error1+warning2; the registered exact-golden case fails1/1. Corrected output is warning1, cached warning1, error1 with no stale warnings, then repair clean; the exact case passes1/1 with both job counts and0 skips/failures/leaks/errors. The source snapshot was restored byte-for-byte afterward; old source/driver/failing JSON and test receipt remain retained.

### What I learned

The first blackbox harness attempt used World.init and failed setup because no normal compiler executable had been installed in this new driver-only lane. The test now uses ordinary disk temporary directories and the existing bounded external-process capture helper directly; no fake BENI_EXE or compiler test hook was added. In-source lifetime tests remain supplemental; this corpus/API executable is the defect's closed-box evidence under Rule3. The new focused build is self-hosted Debug; parent full gates and integration remain pending.
