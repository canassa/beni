## 2026-10-21 14:07 CEST — the exports output key

**What I did**

- Built `boundary.md` §5.2's `"exports"` key (PR #533, §9.12 (c)): a platform declares `"exports": "program"`, the app lists the names, and the entry file exports `run(main)`'s `default` and each listed name, in development, release and the hoisted release file.
- Added `unknown_exports_mode`, `invalid_entry_export` and the warning `exports_ignored`; the emit phase can now carry a warning, and the emitter refuses a build only for an error.
- Fixtures `run/EntryExports`, `run/ExportsIgnored`, `build/bad/UnknownExportsMode`, `build/bad/InvalidEntryExport`; four blackbox tests; `backend.md` §2; the skill's project reference.

**What I learned**

- The release renamer's alphabet holds `$` and `_`, so a two-character short name can be ``; a binding the entry file owns must be longer than eight characters, not only start with `$`.
- A late diagnostic was always an error: `renderLate` hard-coded the severity, and the emitter refused a build on any diagnostic. A warning from the emit phase needed both to change.
- A heredoc that feeds `python3 -` loses one backslash per Zig multiline-string line when written through Python string literals; a stray `cat` before it swallows the script.
