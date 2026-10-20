# 107 — One skill folder for every coding agent

*2026-10-20. Research only: no compiler, platform or application source changed. Issue #518.
Every page named below was read on 2026-10-20; a quote is the page's own sentence, so a reader
can find it again. Where a vendor page says nothing, the table says "not stated", never a guess.*

## 1. The question, and the answer

A coding agent that writes beni knows Elm and writes Elm: `x :: xs`, `->`, `()`, a curried call,
a `let … in`. beni refuses all of it. The owner asked for a way to hand an agent beni's rules,
installable into whatever agent harness a developer uses, kept current with the compiler, and
not embedded in the binary (#518).

**One folder of Markdown files serves all six harnesses, eight surfaces.** The format is the Agent Skills
standard: a directory named after the skill, a `SKILL.md` whose YAML frontmatter has a `name` and
a `description`, and further Markdown files beside it that the agent reads on demand. Claude Code,
Codex CLI, opencode, Cursor, Gemini CLI and the three GitHub Copilot surfaces each read that
format from a directory of their own; the only thing that differs from one harness to the next is
**where** the folder is put. So the deliverable is one folder, `skills/beni/`, and the install
step is a copy (or a symlink) of that folder into the skills directory the user names. §6 gives
the recommendation in full.

## 2. The standard: Agent Skills

The specification is <https://agentskills.io/specification>; its repository is
<https://github.com/agentskills/agentskills>, and Anthropic's own skills are at
<https://github.com/anthropics/skills>. What it fixes, each with the sentence that fixes it:

| Rule | The specification's words |
|---|---|
| the file | a directory holding `SKILL.md`, "YAML frontmatter followed by Markdown content"; optional `scripts/`, `references/`, `assets/` |
| `name` | "Must be 1-64 characters", "May only contain unicode lowercase alphanumeric characters (`a-z`, `0-9`) and hyphens (`-`)", "Must not contain consecutive hyphens (`--`)", "Must match the parent directory name" |
| `description` | "Must be 1-1024 characters" |
| optional fields | `license`; `compatibility` ("Must be 1-500 characters if provided"); `metadata`, a string map; `allowed-tools` (experimental) |
| loading | three levels: the metadata (about 100 tokens) at startup; "The full `SKILL.md` body is loaded when the skill is activated"; "Files (e.g. those in `scripts/`, `references/`, or `assets/`) are loaded only when required" |
| extra files | "When referencing other files in your skill, use relative paths from the skill root"; "Keep file references one level deep from `SKILL.md`" |
| size | "Keep your main `SKILL.md` under 500 lines"; the body "< 5000 tokens recommended" |
| where the folder lives | not mandated: "the Agent Skills specification does not mandate where skill directories live (it only defines what goes inside them)" (<https://agentskills.io/client-implementation/adding-skills-support>). That page recommends `<project>/.agents/skills/` and `~/.agents/skills/` for "Cross-client interoperability", and notes that "Some implementations also scan `.claude/skills/`" |
| install, symlinks | the specification says nothing about either |

The client guide relaxes the `name` rule for loaders ("Name doesn't match the parent directory
name → warn, load anyway"), but Cursor states the rule and VS Code states its effect ("silently
fail to load", §3), so the folder is named `beni` and the frontmatter says `name: beni`.

## 3. Harness by harness

The columns are the two directories a user installs into, the format, what the harness requires
in the frontmatter, whether it reads the extra files, and its size limits. "Also reads" lists
the other harnesses' directories it scans, which is what makes one install serve two.

### 3.1 Claude Code

Sources: <https://code.claude.com/docs/en/skills> (skills), <https://code.claude.com/docs/en/memory>
(memory), <https://code.claude.com/docs/en/env-vars>, the changelog
<https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md> (head `2.1.304`).

| Item | Finding |
|---|---|
| user directory | `~/.claude/skills/<skill-name>/SKILL.md` |
| project directory | `.claude/skills/<skill-name>/SKILL.md`, "in the directory where you start it and in every parent directory up to the repository root"; nested `.claude/skills/` load on demand (the changelog: 2.1.6 added them, 2.1.178 changed when they load) |
| also reads | plugin skills `<plugin>/skills/<name>/SKILL.md`; the enterprise managed directory. **Not `.agents/skills/`**: no line of the skills page, the plugin pages or the changelog names it, and the memory page says of `AGENTS.md` discovery "**Not read**: … anything under a `.agents/` directory" |
| frontmatter | `name` optional ("Defaults to the directory name"), `description` "Recommended"; extra fields (`when_to_use`, `argument-hint`, `disable-model-invocation`, `user-invocable`, `context`, `paths`, `hooks`) are Claude Code's own: "Outside Claude Code, you can use only the fields in the Agent Skills spec", and a skill packaged with one of them "fails with a hard error instead of ignoring the field" |
| extra files | yes: "letting Claude access detailed reference material only when needed"; "Reference supporting files from `SKILL.md` so Claude knows what each file contains and when to load it" |
| size | "Keep `SKILL.md` under 500 lines"; the listing of all descriptions has a budget of "1% of the model's context window" (fallback 8 000 characters), raised by `skillListingBudgetFraction` or `SLASH_COMMAND_TOOL_CHAR_BUDGET`; "the combined `description` and `when_to_use` text is truncated at 1,536 characters in the skill listing" |
| symlinks | followed: "a `<skill-name>` entry in the enterprise, personal, or project location can be a symlink to a directory elsewhere on disk" |
| install | copy or link the folder; `/reload-skills` re-scans without a restart (the changelog's 2.1.152 entry); plugins through a marketplace |
| instruction file | `CLAUDE.md` (`~/.claude/CLAUDE.md`, `./CLAUDE.md` or `./.claude/CLAUDE.md`, `CLAUDE.local.md`, parents at launch, subdirectories on demand); `@path` imports, relative or absolute, four hops; an import outside the project from a project file asks once; "target under 200 lines per CLAUDE.md file". `AGENTS.md` is read when no `CLAUDE.md` exists (the changelog's 2.1.277 entry) |

### 3.2 Codex CLI

Sources: <https://learn.chatgpt.com/docs/build-skills> (the Codex docs moved there from
`developers.openai.com/codex/`), <https://learn.chatgpt.com/docs/agent-configuration/agents-md>,
<https://learn.chatgpt.com/docs/config-file/config-reference>, and the source
<https://github.com/openai/codex> (`codex-rs/ext/skills/src/host_roots.rs`,
`codex-rs/skills/src/parser.rs`, `codex-rs/config/src/config_toml.rs`).

| Item | Finding |
|---|---|
| user directory | `$HOME/.agents/skills`; `$CODEX_HOME/skills` is read but deprecated (`host_roots.rs`: "Deprecated user skills location (`$CODEX_HOME/skills`), kept for backward compatibility") |
| project directory | "Codex scans `.agents/skills` in every directory from your current working directory up to the repository root"; the root is the directory holding `.git` by default |
| also reads | `/etc/codex/skills` (admin) and the skills bundled with Codex; and `<dir>/.codex/skills` for each project `.codex/` folder (`codex-rs/ext/skills/src/host_roots.rs:86-93`, `SkillScope::Repo`), which no page names |
| frontmatter | the page: "The `SKILL.md` file must include `name` and `description`"; the code (`parser.rs`) caps the name at 64 characters (`MAX_NAME_LEN`), falls back to the folder name when `name` is missing, and refuses a missing description; no character or folder-match rule in the code |
| the standard | "Skills build on the open agent skills standard" |
| extra files | `scripts/`, `references/`, `assets/`, loaded on demand; a skill may add `agents/openai.yaml` for Codex-only settings |
| size | the skill list gets "at most 2% of the model's context window, or 8,000 characters when the context window is unknown"; `skills.max_context_tokens` raises it, "Explicit values are capped at `10000` tokens"; a scan reads at most 20 000 entries per root. **When a user names a skill (`$beni`), Codex injects at most 8 000 bytes of its `SKILL.md`** and warns "Skill `…` exceeded the main prompt context limit and was truncated." (`codex-rs/ext/skills/src/render.rs`, `MAX_SKILL_PROMPT_BYTES = 8_000`) |
| symlinks | "Codex supports symlinked skill folders and follows the symlink target when scanning these locations" |
| install | copy the folder: "Codex detects newly installed skills automatically; if one doesn't appear, restart Codex"; also `$skill-installer` and plugins. Two skills with one `name` at two real paths are both listed (`host_merge.rs`), not merged. `[[skills.config]]` in `config.toml` turns one skill on or off by `path` or `name`; it adds no directory |
| instruction file | `AGENTS.md`: `~/.codex/AGENTS.md` (`AGENTS.override.md` first), then one file per directory "from the root down" to the working directory, joined, "32 KiB by default" (`DEFAULT_PROJECT_DOC_MAX_BYTES`), after which "Codex … stops adding files once the combined size reaches the limit". No `@path` import is documented |

### 3.3 opencode

Sources: <https://opencode.ai/docs/skills>, <https://opencode.ai/docs/rules>, and the source
<https://github.com/anomalyco/opencode> (`packages/core/src/config/discovery.ts`,
`packages/core/src/config/plugin/skill-scan.ts`, `packages/core/src/config/plugin/skill-file.ts`).

| Item | Finding |
|---|---|
| user directory | "Global definitions are also loaded from `~/.config/opencode/skills/*/SKILL.md`, `~/.claude/skills/*/SKILL.md`, and `~/.agents/skills/*/SKILL.md`" |
| project directory | `.opencode/skills/`, and "any matching `.claude/skills/*/SKILL.md` or `.agents/skills/*/SKILL.md` along the way", walking up "until it reaches the git worktree" (the page; the code, `util/src/fs-util.ts`, walks up to `/`) |
| also reads | the `skills` config key: more directories, or `http(s)` URLs |
| frontmatter | "Each `SKILL.md` must start with YAML frontmatter"; `name` and `description` required; `name` matches `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–64 characters, and must "Match the directory name that contains `SKILL.md`"; "`description` must be 1-1024 characters"; `license`, `compatibility`, `metadata` optional. The loader (`skill-file.ts`) is laxer than the page: a missing `name` falls back to the directory name |
| the standard | the page names "the Agent Skills spec" and its fields |
| extra files | the skill's directory is scanned and at most ten files are listed to the model ("file list is sampled"); the model reads them on demand |
| size | the name and description limits above; nothing on the body |
| symlinks | followed: `skill-scan.ts` `stat`s a symlink and treats it by its target's type; the scan goes six levels deep and skips dot-directories |
| install | copy the folder; no install command. Two skills with one folder name: the later root wins silently (`skill-file.ts`, `compatibility.ts`): `.agents` beats `.claude`, and `~/.config/opencode/skills` beats both |
| instruction file | `AGENTS.md` in the project root, found by walking up; `~/.config/opencode/AGENTS.md`; `CLAUDE.md` as a fallback; the `instructions` key adds paths, globs and URLs. "opencode doesn't automatically parse file references in `AGENTS.md`" |

### 3.4 Cursor

Sources: <https://cursor.com/docs/context/skills>, <https://cursor.com/docs/context/rules>, the
2.4 changelog <https://cursor.com/changelog/2-4> (2026-01-22: "Cursor now supports Agent Skills
in the editor and CLI").

| Item | Finding |
|---|---|
| user directory | `~/.cursor/skills/`, `~/.agents/skills/` |
| project directory | `.cursor/skills/`, `.agents/skills/`, "anywhere inside your repository" (a nested folder is scoped to its directory) |
| also reads | "For compatibility, Cursor also loads skills from Claude and Codex directories": `.claude/skills/`, `.codex/skills/`, `~/.claude/skills/`, `~/.codex/skills/` |
| frontmatter | `name` ("Lowercase letters, numbers, and hyphens only. Must match the parent folder name.") and `description` required; `paths`, `disable-model-invocation`, `icon`, `color`, `metadata` optional; "Agent Skills is an open standard. Learn more at agentskills.io." |
| extra files | yes: "Skills can also include optional directories for scripts, references, and assets", by relative path from the skill root |
| size | none stated for a skill; a rule file: "Keep rules under 500 lines" |
| symlinks | not stated |
| install | copy into a skills directory; `/create-skill`; `/migrate-to-skills`; only `~/.cursor/skills/` syncs to cloud agents |
| instruction files | `.cursor/rules/**/*.mdc` with `description`, `globs`, `alwaysApply`; `@file` in a rule is read on demand ("The file's contents are not inlined into the prompt"); `AGENTS.md` "in the project root and subdirectories" |

### 3.5 Gemini CLI

Sources: <https://geminicli.com/docs/cli/skills/>, <https://geminicli.com/docs/cli/creating-skills/>,
<https://geminicli.com/docs/cli/gemini-md/>, <https://geminicli.com/docs/reference/memport>, and the
source <https://github.com/google-gemini/gemini-cli> (`packages/core/src/skills/skillLoader.ts`,
`packages/cli/src/utils/skillUtils.ts`). The skills page carries a notice: "Unpaid tier and Google
One users: Gemini CLI was replaced by Antigravity CLI on June 18th, 2026."

| Item | Finding |
|---|---|
| user directory | "User skills: Located in `~/.gemini/skills/` or the `~/.agents/skills/` alias" |
| project directory | "Workspace skills: Located in `.gemini/skills/` or the `.agents/skills/` alias"; "the `.agents/skills/` alias takes precedence over the `.gemini/skills/` directory"; workspace skills are off in an untrusted folder |
| also reads | extensions' skills and the built-in ones, below the user's in precedence |
| frontmatter | "the necessary YAML frontmatter (`name` and `description`)"; the loader checks only that both are strings and replaces `: \ / < > * ? " \|` in a name with `-` |
| the standard | "Based on the Agent Skills open standard, a "skill" is a self-contained directory" |
| extra files | "When a skill is activated, the model is granted access to this entire directory"; the best-practices page: "Move detailed reference material, schemas, and examples into separate files in a `references/` directory" |
| size | the body "Loaded only after the skill triggers (<5k words)" (`docs/cli/skills-best-practices.md` in the repository); no hard limit |
| symlinks | `gemini skills link <path>` writes one (`fs.symlink`, a junction on Windows); the loader globs `SKILL.md` and `*/SKILL.md` and follows it |
| install | `gemini skills install <git-url or path> --consent` (a copy, `fs.cp` recursive), `gemini skills link <path>`, `/skills reload`, `--scope user|workspace`. Two skills with one name: the higher tier wins, with the warning "Skill conflict detected" (`skillManager.ts`) |
| instruction file | `GEMINI.md`: `~/.gemini/GEMINI.md`, the working directory and its parents "up to either the project root (identified by a `.git` folder) or your home directory", subdirectories (200 at most); `context.fileName` renames it, the example being `["AGENTS.md", "CONTEXT.md", "GEMINI.md"]`; `@file.md` imports, relative or absolute, five levels, confined to the project root |

### 3.6 GitHub Copilot

Three surfaces read skills: Copilot in VS Code
(<https://code.visualstudio.com/docs/copilot/customization/agent-skills>,
<https://code.visualstudio.com/docs/copilot/reference/copilot-settings>), the Copilot CLI
(<https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills>) and the
cloud coding agent (<https://docs.github.com/en/copilot/concepts/agents/about-agent-skills>,
<https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-skills>).

| Item | VS Code | CLI | coding agent (cloud) |
|---|---|---|---|
| user directory | `~/.copilot/skills/`, `~/.claude/skills/`, `~/.agents/skills/` | `~/.copilot/skills`, `~/.agents/skills`; `COPILOT_SKILLS_DIRS` adds directories | runs in the cloud: the docs warn against "assuming that a personal skill is available to an agent running in the cloud" |
| project directory | `.github/skills/`, `.claude/skills/`, `.agents/skills/` | the same three | the same three |
| frontmatter | `name`: "Only lowercase letters, numbers, and hyphens are allowed", "Must match the parent directory name. Maximum 64 characters."; `description`: "Maximum 1024 characters." | `name`, `description` required; `license`, `allowed-tools` optional | `name` "must be lowercase, using hyphens for spaces" |
| extra files | "Skills load content progressively"; "Use Markdown links or `#file:` references with paths relative to the `SKILL.md` file"; an unreferenced file is not loaded | "Optionally, add scripts, examples or other resources to your skill's directory" | "Copilot automatically discovers all of the files in the skill's directory" |
| size | none stated | none stated | none stated |
| install | copy; the customizations editor; a marketplace that "doesn't overwrite an existing skill". Two skills with one name: "If another supported location contains a skill with the same name, both skills appear on the Skills page." | copy; `/skills add` adds "a skill from a file, URL, or directory"; `/skills reload`; `gh skill install OWNER/REPO SKILL`. Two with one name: "first found wins for duplicate names" | `gh skill install` (public preview, GitHub CLI 2.90.0+) |
| the standard | "Agent Skills is an open standard that works across multiple AI agents" | not named | "The Agent Skills specification is an open standard" |
| instruction files | `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` (`applyTo`), `AGENTS.md` (`chat.useAgentsMdFile`, default on), `CLAUDE.md` | the same, plus `$HOME/.copilot/copilot-instructions.md` and `.claude/CLAUDE.md` | the same; nested `AGENTS.md`, "the nearest … will take precedence" |

Symlinked skill folders: not stated on any Copilot page.

## 4. Can one folder serve all of them?

Yes. Every harness in §3 loads a directory that holds a `SKILL.md` with `name` and `description`
and reads the files beside it when the body points at them. The intersection of their rules is
the specification's own, and the folder meets it:

- `name: beni`, the folder named `beni` — lower case, under 64 characters, equal to the folder
  name, which Cursor states and VS Code enforces ("silently fail to load").
- `description` under 1 024 characters, and under Claude Code's 1 536-character listing cut.
- `SKILL.md` under 500 lines and under 8 000 bytes (Codex's cut, §3.2); every other file one
  level down, in `references/`, and named from `SKILL.md` with a relative path, because VS Code
  loads only what `SKILL.md` names: "If a file isn't referenced in the instructions, it won't be
  loaded."

- No field outside the specification in the frontmatter. Claude Code's page: "Outside Claude
  Code, you can use only the fields in the Agent Skills spec", and a packaged skill that carries
  another client's field "fails with a hard error instead of ignoring the field" (§3.1).
- A `.beni` code block is Markdown to every harness; none of them runs anything in a skill
  unless the body asks for a script, and the beni skill ships none.

What one folder cannot do is choose its directory. Three names cover the six harnesses:

| Directory | Read by |
|---|---|
| `~/.agents/skills/` and `.agents/skills/` | Codex CLI, opencode, Cursor, Gemini CLI, Copilot (all three surfaces) — every harness but Claude Code |
| `~/.claude/skills/` and `.claude/skills/` | Claude Code, opencode, Cursor, Copilot in VS Code; the Copilot CLI and the coding agent read a project's `.claude/skills/` but no `~/.claude/skills/` |
| the harness's own: `~/.cursor/skills/`, `~/.copilot/skills/`, `.github/skills/`, `~/.config/opencode/skills/`, `.opencode/skills/`, `~/.gemini/skills/`, `.gemini/skills/`, `~/.codex/skills/` (deprecated) | that harness |

An instruction file (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursor/rules/*.mdc`,
`.github/copilot-instructions.md`) is the other format every harness reads, and it is the wrong
one for this content. It is always on, so every line costs context on every task, beni or not;
each harness caps it (Codex stops at 32 KiB, Claude Code's target is 200 lines); it has a
different name and frontmatter per harness, so five files must stay in step; and
it cannot point at a second file in a way all of them follow (opencode: "opencode doesn't
automatically parse file references in `AGENTS.md`"; the Copilot CLI expands `@` references in
`AGENTS.md` and `CLAUDE.md` but "File references are not expanded in `GEMINI.md` or
`*.instructions.md` files",
<https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions>). A skill is loaded when its description
matches the task and reads its references only as needed, which is what a language guide wants.

## 5. How a user installs it into each harness

The install is one operation everywhere: put the folder `beni/` into a skills directory. The
compiler ships the folder beside the binary (`<prefix>/share/beni/skills/beni/`), and
`beni skill install <dir>` copies it there — the user names `<dir>`, because no two machines
agree on a home directory and a cloud agent has none. `--link` writes a symlink instead: Claude
Code and Codex document that they follow one, opencode's loader does, Gemini CLI writes one with
`gemini skills link`, and Cursor and Copilot say nothing. A linked skill follows every
`zig build install`; a copied one is refreshed with `--force`.

| Harness | `<dir>` for one user | `<dir>` for one project |
|---|---|---|
| Claude Code | `~/.claude/skills` | `.claude/skills` |
| Cursor | `~/.agents/skills` (or `~/.cursor/skills`) | `.agents/skills` (or `.cursor/skills`) |
| GitHub Copilot, VS Code and CLI | `~/.agents/skills` (or `~/.copilot/skills`) | `.agents/skills` (or `.github/skills`) |
| GitHub Copilot, coding agent | — (cloud) | `.agents/skills` (or `.github/skills`) |
| Codex CLI | `~/.agents/skills` | `.agents/skills` |
| opencode | `~/.agents/skills` (or `~/.config/opencode/skills`) | `.agents/skills` (or `.opencode/skills`) |
| Gemini CLI | `~/.agents/skills` (or `~/.gemini/skills`) | `.agents/skills` (or `.gemini/skills`) |

One copy covers every harness on one machine: `beni skill install ~/.agents/skills`, and for
Claude Code a symlink `~/.claude/skills/beni → ~/.agents/skills/beni`, which Claude Code follows
and loads once ("loads the skill once even if several locations point at the same target"); or
`beni skill install --link` into both directories, so both point at the installed folder and one
`zig build install` refreshes both. **Two copies are not the same as one**, because Cursor,
opencode and Copilot in VS Code read both directories: VS Code shows two `beni` skills ("both
skills appear on the Skills page"), the Copilot CLI takes the first it finds, Gemini CLI takes
the higher tier with a warning, opencode takes the later root silently, and Codex lists both. A
`--force` refresh of one copy then leaves a stale copy that some harness reads with no warning.

After a copy, the harness picks the skill up at its next start, or on its reload command
(Claude Code `/reload-skills`, Copilot CLI `/skills reload`, Gemini CLI `/skills reload`).

A repository that wants every contributor's agent to have the skill commits it under
`.agents/skills/beni/` and `.claude/skills/beni/` (a symlink from one to the other, where the
harness follows it), or runs `beni skill install .agents/skills` in its setup. The `canassa/beni`
repository itself needs neither: its agents work on the compiler, and `.claude/skills/` there
holds the compiler's skills, not the language's.

## 6. Recommendation

1. **One folder, `skills/beni/`, in the Agent Skills format.** `SKILL.md` is the index: the
   frontmatter, the ten rules an Elm programmer breaks first, and one line per reference file
   saying what it holds. The topics live one level down in `references/` — the departures from
   Elm, calls and blocks, lists and ownership, static dispatch, effects and `Task`, schemas,
   markup, the platforms, the project file, the CLI — each short enough to read whole. The
   repository folder is named `skills/` and not `.agents/skills/` because a folder there loads into
   every compiler agent, and because `skills/<name>/SKILL.md` is the layout a Claude Code
   plugin uses for its skills (§3.1), so the repository can become one without moving the folder.
2. **Install, not embed.** `zig build install` copies the folder to `<prefix>/share/beni/skills/beni/`
   byte for byte; the binary carries none of it. A Nix package puts the same tree under
   `$out/share/`.
3. **`beni skill`** prints the folder's path; **`beni skill install [--link] [--force] <dir>`**
   puts it into the directory the user names, under `<dir>/beni/`, and refuses to replace an
   existing one without `--force`. The command guesses no home directory. The specification is
   `frontend.md` §12.
4. **Kept current by a gate**, not by discipline alone: every `beni` code block in the folder is
   checked by the compiler of the same commit (a refused example must fail with the code it
   names), every command and flag of `beni help` is in the CLI file, and the API reference of
   core and of each platform is generated from `beni dump --stage=interface` and compared. The
   rule in `CLAUDE.md` (which `AGENTS.md` links to) says that a change a user sees updates the
   folder in the same PR.
5. **Generate the API reference, write the rest by hand.** The interface dumps are facts (`beni
   dump --stage=interface` over each package at master `4586e4fb0`, counted by the review of #523: 681 lines, 31 KB, for core and 837
   lines, 36 KB, for the five platforms): facts the compiler prints. Prose about when to use
   them is not. The generator rewrites the dump into beni's notation (`frontend.md` §12.1), so
   every signature in the file is in beni's notation. Generated files are committed, so a reader on
   GitHub and a `gh skill install` see the same tree the build installs.

## 7. What this note did not settle

- Whether Claude Code will read `.agents/skills/`: nothing in its docs or changelog says so
  today (its issue tracker: anthropics/claude-code#16345 is open since 2026-01-05, and two
  requests were closed as not planned). When it does, one directory covers every harness, and
  `beni skill`'s help text changes one line.
- `.cursorrules` and the exact date Cursor started reading `AGENTS.md` are not on a live
  vendor page; neither matters for a skill.
- opencode's page states a name pattern and a length that its loader does not enforce; the
  folder meets the page's rule, so where the rule is enforced does not matter here.
- Symlinks: Claude Code and Codex document that they follow one, opencode's code does, Gemini
  CLI writes one with `skills link`; Cursor and Copilot say nothing. `--link` is an option,
  never the default.
