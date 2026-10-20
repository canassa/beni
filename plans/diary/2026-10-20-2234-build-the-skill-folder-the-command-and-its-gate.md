## 2026-10-20 22:34 CEST — Build the skill folder, the command and its gate

**What I did**

- Wrote `skills/beni/`: `SKILL.md` with the twelve rules an Elm programmer breaks first,
  ten topic files under `references/`, and six generated `api-*.md` files. Every one of
  the 37 `beni` code blocks is checked by the compiler and formatted by it; the refused
  ones fail with the code they name.
- Built `beni skill` and `beni skill install [--link] [--force] <dir>` as `frontend.md`
  §12 says: the folder is found from the real path of the running binary, `--force`
  replaces only a symlink or a directory whose `SKILL.md` says `name: beni`, a
  `<dir>/beni` that is the installed folder or lies inside it is refused, and the copy
  goes through `.beni-new` and `.beni-old`.
- Built `tests/skill_api.zig`, which rewrites `beni dump --stage=interface` into beni's
  notation, and `zig build skill-api`; `zig build install` puts the folder under
  `share/beni/skills/`; the gate `tests/blackbox/skill_test.zig` runs inside
  `test-blackbox`, one test per item and one per package.
- Added the rule to `CLAUDE.md`. `zig build gates` is green on the rebased tree.

**What I learned**

- `World.copyTreeInto` with an empty skip prefix skips every file: `startsWith(name, "")`
  is true. Two tests passed only after the prefix became `"."`.
- `beni dump --stage=interface` reads a package as app modules when `--root` is absolute
  (#534); the generator and the gate pass the repository root as `.`.
- An `ArrayList`'s `items` slice is not what `allocator.free` wants; a unit test that
  frees it crashes the safe allocator. An arena per test is the simple shape.
- `fmt --check` wants a short body on the `=` line, a `case` body on the next line, and
  one blank line between branches; pasting the formatter's own output is the only way to
  write an example that passes first time.
