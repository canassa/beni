## 2026-11-09 06:14 CET — emit rows carry a unit's Js.module imports

**What I did**

- Reproduced #2019 on master: a plain development build of a Worker with a
  Durable Object writes `Rt$$cloudflare_workers.DurableObject` in
  `_platform/Rt.mjs` with no `import` of `cloudflare:workers`.
- Found the cause. A development build takes an embedded module's units
  from the binary's emit rows and rebuilds the head. A row unit carried its
  cross-module names (`needed`) but not its `Js.module` specifiers, so a
  taken `Rt.instanceClass` left `host_imports` empty. `--release` reads no
  emit row, so it was correct.
- Fixed it: the funnel records each `Js.module` call
  (`Funnel.Recorder.askHost`), the row stores a unit's specifiers (format
  v4, `EmitPack.Unit.hosts`), and `Lower.replayReuse` replays them.
  `backend.md` §9 *What a unit carries* names the new entry.
- The corpus did not see it: every `workers/` build had `--test-hooks`.
  A script may now begin `{"hooks": false}`: the harness builds without
  the flag and the driver asks no mark. `workers/ObjectDevImport` uses it;
  red before the fix, green after.

**What I learned**

- Under `--test-hooks`, every unit that lowers a `case` asks the
  `test_hooks` fact (`Lower.developmentArm`), so letting such a build read
  the emit rows would still lower nearly everything afresh. A build
  without the flag is the only way for the corpus to take the user's path.
- Every `Object*` fixture had the same missing import in a plain build;
  only the flag hid it.
