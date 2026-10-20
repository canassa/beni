## 2026-10-20 21:44 CEST — Answer the review of the skill spec

**What I did**

- Read the reviewer's report on #523 (`beni-skill-review`): one hazard in `--force`, a
  generated reference that prints notation beni refuses, a false Codex claim, eight bare
  `§12.x` references in `frontend.md` §11 that now pointed at the new section, no byte cap
  for Codex's 8 000-byte cut, and a gate that fits the budget only when split.
- Fixed all of it in the spec: `--force` replaces only a symlink or a directory whose
  `SKILL.md` says `name: beni`, and refuses a `<dir>` inside the installed folder; the
  copy is renamed over the old entry through `.beni-old`; the generator rewrites the dump
  into beni's notation; the gate is one test per item and one per package for the API
  files, with the measured costs; the hidden migration flags a diagnostic names are on a
  list the gate keeps, so `beni help` does not change; `SKILL.md` stays under 8 000
  bytes; the eight references say `language.md`.
- Fixed the note: the Codex `.codex/skills` root is in the source, two copies of one
  skill behave differently per harness (so one copy plus a link is the recipe), the
  Copilot CLI reads no `~/.claude/skills`, and the smaller source errors.
- Opened #529 (expressions and values in the references are not checked) and #530 (a
  copied skill has no stamp) for the debt the review named.

**What I learned**

- A `str.replace` with no count is how a whole section lands inside a table row; every
  scripted edit of a document asserts its match count now.
- `beni` is the name of the repository and of many directories: a `--force` that deletes
  any `<dir>/beni` is a data-loss hazard, not a convenience. The replaced thing must prove
  it is a beni skill.
- The gates' ReleaseSafe beni costs 1.2 G instructions for one `dump --stage=interface`
  of core, so six dumps in one test would sit at the budget on day one. Measure before
  the test exists, not after it fails.
- The session was killed by the OOM daemon once (an uncapped `nix search` elsewhere);
  a background job that waits on the lock dies with the session, so check the log before
  assuming it ran.
