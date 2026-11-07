## 2026-11-07 22:33 CET — remove the worker launch gate

**What I did.** Removed `--allow-unchecked-workers` and the launch refusal it lifted (#1689, PR #2231): `Cli.zig`,
both `Command.zig`s, `Emit.zig`'s two sites, the corpus harness's `unchecked_workers` marking, the flag in
`platform_test.zig`, and `build/bad/UncheckedWorkers`. `workers.md` has a *Launch amendment, 2026-11-07*; the
skill's `Worker.open` example is now a checked block. On master, `browser/dedicated/RoundTrip` without the flag is
`invalid_entry_kind`; here it builds. `bench/size.mjs --pages-only` and every `browser/dedicated` page, dev and
release, are byte-identical to master.

**What I learned.** `beni check` never reports `worker_realm_violation`: `RealmCheck` runs only in `build`, on the
kept code, so the skill cannot show a refused realm example (#2230). `check` of a module with no `main` runs no
launch discovery. The Mac scratchpad was shared with the #2211 agent's mirror (`scratchpad/wt`): keep a mirror
in a directory named for the task.
