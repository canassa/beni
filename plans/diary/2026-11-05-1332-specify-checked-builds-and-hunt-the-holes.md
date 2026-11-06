## 2026-11-05 13:32 CET — Specify checked builds and hunt the holes (#1988)

**What I did**
- Wrote the contract for #1988: `language.md` §13 (the three builds, the guarantee, `Int`, each `Float` row, division, a crash, `--release`), `boundary.md` §4.3, `backend.md` §16, with amendments in place wherever a statement changed (`language.md` §0, §2.5, §6, `checker.md`, `backend.md` §2, §4, §9, §12, `boundary.md` §4.2, §9.8.10, §9.8.14) and in `CLAUDE.md`. No section was renumbered, and no code changed.
- Added research 110 (the survey of other languages, whole, with its caveats) and 111 (the hole hunt).
- Ran about 130 small beni programs on master `89acc97412` on dagon, under Node and happy-dom, in development and `--release --allow-debug`, and had two read-only audits done: the optimiser's assumptions, and every host call and cast in core and the platforms.
- Opened #1992–#1998, commented on #1282 and #1985.

**What I learned**
- The largest gap was not in #1988's list. A checked `+` cannot be written under a `number` type variable: `Int` and `Float` are one JavaScript number and such a function has one body, so `twice 9007199254740991` must crash and `twice 1.0e308` must not, in the same `+`. That is #1996 and it is the owner's.
- A value can be wrong with no NaN at all: `Html.targetValue` on a `<div>` gives `undefined` typed `String`, and the program fails later in `++` with an unrelated message. Arithmetic checks cannot see this class (#1997).
- The defect path has two gaps of its own (#1994), which a test of `Debug.todo` in a fiber under `Tea` does not show. A plain `Browser.program` never hands `Task.onDefect` its hook.
- A check can make a promise false. `Duration` promises "never a crash", `core`'s `append`s write `+` on strings typed `Int`, `Int.mod` adds its modulus, and a WebSocket peer picks a number that would overflow. Each is a false crash unless core changes with the check.
- `language.md` §6 said arithmetic "cannot fail", and the optimiser's freedom rests on it. A build with checks and the optimiser is a new combination, so a third corpus pass is the only way to see the optimiser drop a check.
- `perl -pe` with `§` in the pattern and `-CSD` silently matches nothing, because the script's bytes are not decoded. Two of my edits vanished this way, and only a grep showed it. In a shell, use an ASCII anchor.
- `backend.md` has about 1 090 lines of double-encoded text (`Â§`) on master. I left them alone: a new section in plain UTF-8 sits at its end, and Edit's anchors avoid them.
