## 2026-10-16 00:04 CEST — share cold validators where they save bytes

**What I did.** Schema slice B (#192), on top of #204. A `--release` build now calls a `core/Schema` helper for a failure branch its workers repeat. The helpers are `compiledDeep`, `compiledMissing`, and `badString`/`badInt`/`badBool`/`badFloat`/`badFinite` for a required primitive field of a JSON object. A helper is used only when the live worker sets call it at least a measured number of times: 4 for a field helper, 24 for the depth bound and the missing key. `SchemaShare` counts the calls after reachability. `Emit.shareValidators` roots the chosen helpers and walks again. The worker keeps every test in place and calls the helper only to make the issue. Specified in `schema.md` §6 *Validators shared across schemas* and §16 *As built — slice B*. Fixtures `run/SchemaSharedValidators` (its release build shares every helper, its development build none, one golden equal to master's interpreter) and `emit/release/app/SchemaSharedValidators`.

**What I learned.**
- Brotli punishes naive sharing. The repeated in-place branch compresses to a few bytes. A `--release` call cannot be inlined back, because the helper is another module's value. So a helper wins only past a count, and the count differs per helper.
  - A table helper (`compiledFixed`) grew every small program.
  - `badField` won on Conduit and lost +113 on a program with nearly as many calls. Refused.
  - One run cut 6.5 kB of raw JavaScript and still grew 113 bytes under brotli.
- Speed decided the rest. A helper that runs the tests saved more (Conduit −297/−220) but slowed decode 1–3%, and 5–7% when it read the key itself. Keeping the success path in place and sharing only the cold half is speed-neutral.
- Measuring that needed an interleaved in-process A/B. The machine's load swung from 3 to 14 during the session, which moved the alternating-process figures by ±10%.
- Result: Conduit −185 tea / −136 direct, `bench/size.mjs` release −412, and no measured program grows.
