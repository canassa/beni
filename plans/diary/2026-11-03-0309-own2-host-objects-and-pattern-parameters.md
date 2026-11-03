## 2026-11-03 03:09 CET — own2: host objects, escaped results, pattern parameters

**What I did**
- Built #1735's rule (the manager's decision): a `foreign`'s unknown result is `host`, a new arrival and leaf kind. It is apart from every target that is still writable, and a write of it is refused `escaped`. This covers imported foreigns and parameterless ones (`Js.null`). `Task.scope`'s handle is now host, so `Control` 17:5 is accepted. Spec §2.10 *host objects*; new file `Host.zig`; block version 18.
- Found and fixed #1744: an object a body hands to JavaScript and returns was read off `fresh`. Six sanitiser traps: a site, a callee's fresh list, a callback's answer, an escape through a call, an escaped answer of a supplied list, and a group's late escape.
- Found and fixed #1745: a lambda's pattern parameter took the pattern instruction's type, which is not recorded, so its place was a type variable's. `Dict.fromList`'s result held nothing of its argument, and that trapped.
- #1713: a value whose contract holds no object (`Dict.empty`) is a scalar. All 18 `Dict.empty` `top-level` rows are gone. The total went 293 → 279.
- Fixtures: `run/SanitiserEscapedResult`, `SanitiserScopeHost`, `SanitiserLambdaPattern`, `SanitiserEmptyValue`.

**What I learned**
- The host rule is only as sound as escape tracking. The first adversarial probe (a foreign that returns its argument) trapped as soon as `host` was in. The reason: contracts named only parameter escapes, so an own object that escapes was invisible to the callers.
- Checking every described leaf against every escape by the one relation cost `Schema.shapeOf` 3.5× (`cond` records). The fix was to check only leaves that no key reads (a call's subtree is said through its key's leaves), matched by atom. Only an escaped label's answer falls back to the relation.
- An oracle set of 700 probes had no case of a lambda with a pattern parameter. One probe built from `Dict.fromList` found a hole of the whole slot-domain lineage. Probe each core function's real shape, not only the idioms.
- Fixing #1745 exposed a runaway in `Routes.anyPair` under `instSelFeed` (`groupOrder`), which went to #1714. A soundness fix can turn a cheap wrong answer into an expensive right one.
- Running `beni build` inside a fixture directory leaves a `.beni-cache` there, which breaks the corpus walk. Build into scratch with the cwd outside `tests/`.
