---
name: commit
description: Commit (and push) work in this repo's house style — an emoji-prefixed subject line plus a short why-focused body. Use whenever the user asks to commit, save, or "commit and push". Picks the single best-fit emoji from the project map, writes a tight body (no wall of text), commits, and pushes — without asking for confirmation.
---

# commit

Commit the current work in this project's format, then push. **When the user asks
to commit, commit AND push — don't ask for confirmation, don't stop to summarize
first.**

## Message format

```
<emoji> <short subject>

<body>
```

- **Subject** — one line, imperative mood, lower-ish case, no trailing period.
  Keep it short and concrete ("intern identifiers at lex time", not "compiler work").
- **Body** — what was done and *why*, plus context only if it's not obvious.
  **No wall of text. No exhaustive list of every change — that's what the diff is
  for.** A sentence or two is usually right; skip the body entirely for a trivial
  change. Explain intent, not mechanics.
- If the harness supplies a session trailer (`Claude-Session: <url>`), put it last,
  after a blank line.

## Emoji map

Pick the **single** emoji that best fits the dominant change. If a commit spans
two areas, choose the one that's the point of the commit — or split the commit.

| Emoji | Use for |
|-------|---------|
| ✨ | New feature / capability — the default for feature work |
| 🐛 | Bug fix |
| ✅ | Tests — add or fix, corpus fixtures, harness |
| 🔤 | Front end — lexer, parser, AST, BIR |
| 🧮 | Type checker — constraints, unification, inference, diagnostics |
| 📜 | Backend — JS codegen, emit, source maps, DCE |
| 💾 | Incrementality — daemon, caching, interface firewall, dependency graph |
| ⚡ | Performance — profiling, measured wins, budget work (§2) |
| 🏗️ | Structural — refactors, project layout, toolchain plumbing |
| 📦 | Dependencies / lockfiles / submodules — `flake.nix`, `flake.lock`, `references/` |
| 🤖 | AI tooling — skills, agents, prompts (`.claude/`) |
| 📝 | Docs — `docs/design/`, research reports, `CLAUDE.md` |
| 🎨 | Formatting / style only (`zig fmt`; no behaviour change) |
| 🧹 | Cleanup — dead files, `.gitignore`, dedupe |
| 🔧 | Config — settings, env, git plumbing |

If nothing fits, use ✨ and pick a clear subject.

## Procedure

1. **See what's there.** `git status` + `git diff` (and `git diff --cached`). If
   nothing is staged, stage the relevant changes (`git add -A` for a normal
   "commit everything", or the specific paths the user named).
2. **Sanity-check the staged set** — no scratch files, build artifacts or
   **secrets**. Never commit `.direnv/`, `zig-out/`, `.zig-cache/` (`.gitignore`
   covers these), and never a Zulip API key or any `ZULIP_*` credential — those
   live in the environment, never in the repo. If something odd is staged, flag it
   rather than committing it blindly.
3. **For code changes**, if you haven't already verified them this session, run
   `zig build test`, `zig build test-blackbox` and `zig build fmt-check` in the dev shell
   (`direnv exec . …`) before committing. Don't commit red or unformatted code.
4. **Prefer several focused commits over one sprawling one.** If the work spans
   the front end and the docs, that is two commits, not one with two emoji.
5. **Pick the emoji** from the map and **write the message** (subject + tight
   body) per the rules above.
6. **Commit** with that message, then **`git push`**. Report the short hash and
   subject when done.

## Notes

- Use a HEREDOC for the message so the blank line and punctuation survive:
  `git commit -F - <<'EOF' … EOF`.
- If the push is rejected (remote moved), pull/rebase and push again; don't
  force-push unless the user says so.
- **This repo currently has no remote**, so the skill cannot push — commit, then
  tell the user it needs `git remote add origin …` before anything can be pushed,
  rather than guessing a URL.
- `references/` holds large vendored submodules (the Zig compiler is ~290MB).
  Commit the submodule *pointer*, never vendored file contents, and never let a
  build artifact from inside a reference tree get staged.
