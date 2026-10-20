## 2026-10-20 20:35 CEST — Research and spec for the beni skill

**What I did**

- Read issue #518: a coding agent that writes beni knows Elm, and beni refuses Elm. The
  owner wants a skill that an agent can install, kept current with each commit, and not
  embedded in the binary.
- Researched how six harnesses load skills and instruction files, from their own pages
  and source: Claude Code, Codex CLI, opencode, Cursor, Gemini CLI and the three GitHub
  Copilot surfaces. Three research agents read the pages in parallel; I checked the
  quotes against the downloaded copies. The note is `docs/design/research/107`. Every
  harness reads the Agent Skills format: a folder with a `SKILL.md` (`name`,
  `description`) and reference files beside it. Only the directory differs.
  `~/.agents/skills` serves every harness but Claude Code; `~/.claude/skills` serves
  Claude Code, opencode, Cursor and the local Copilot surfaces.
- Specified `beni skill` in `frontend.md` §12: the folder `skills/beni/` with an index and
  one file per topic, the generated API references, `zig build install` to
  `<prefix>/share/beni/skills/beni/`, the command (`beni skill` prints the path;
  `beni skill install [--link] [--force] <dir>` copies or links it), and the gate that
  fails when the folder goes stale.
- Probed the compiler for the gate: `beni check` reports every module of a directory, so
  one process checks one group of examples; `beni dump --stage=interface` takes a
  directory and prints one module after the other, so one process per package generates
  the API reference. On the Debug binary the core dump costs 2.4 G instructions, well
  inside one test's budget on the ReleaseSafe build.

**What I learned**

- The research numbers 100 to 106 are taken on open branches; a new note takes the first
  number that no branch holds, so the next merge does not clash.
- Claude Code reads no `.agents/skills/` directory today; its memory page says `.agents/`
  is not read. Every other harness does. So two installs cover one machine.
- Cursor and VS Code enforce that the skill's `name` equals its folder name; opencode's
  page states the rule and its loader does not enforce it. The folder is `beni`, the
  name is `beni`, and the question does not arise.
- `beni fmt` puts a short body on the `=` line, so an example in a skill must be
  formatted by the compiler before it is pasted; the gate runs `fmt --check` on each.
