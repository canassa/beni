# The captain's log

This directory is the captain's log of all work on beni. Each entry is one
file. The rule is in `CLAUDE.md`, *Captain's log*.

## Add an entry

- At the end of a session where you did real work, add one new file.
- Name the file `YYYY-MM-DD-HHMM-<slug>.md`. Use the date and the time of
  the heading, in your time zone. `<slug>` is the title in lower-case kebab
  case, at most 60 characters.
- If the name is taken, add `-2` to it (then `-3`).
- Write the heading on the first line: `## YYYY-MM-DD HH:MM TZ — <short title>`.
  Get the real time with `date`. Then write **What I did** and
  **What I learned**.
- Never edit or delete a past entry. Correct a past statement in a new entry.

Two branches add two different files, so the log never causes a merge
conflict.

## Read the log

The names sort in time order, so `ls plans/diary` lists the log from the
oldest entry to the newest. To read it as one text:

```sh
awk 'FNR == 1 && NR > 1 { print "" } { print }' plans/diary/2*.md
```

## History

Until 2026-10-15, the log was one file, `plans/diary.md`. Each session
appended to its end, so two branches that both logged a session always
conflicted in it (issue #123). The file was split into this directory. The
text of the entries did not change:

- Each of the 224 entries became one file. The heading stays on its first
  line.
- The blank lines at the end of each entry were removed.
- 26 headings from 2026-09-24 to 2026-09-27 have a date and no time. Their
  file names use the time of the commit that added the entry.
- The old file held the entries in the order of their merges. The file names
  sort by the time in the heading, so 83 entries have a different position.
- Two entries hold a stray conflict-marker line (`|||||||`) from an earlier
  merge: `2026-10-14-1627-close-the-final-ownership-audit-gap-before-merge.md`
  and `2026-10-15-0944-research-96-how-to-spell-a-nullary-method-call.md`.
  The split kept them, as it kept all the text.
- The old file started with these lines, which this file replaces:
  "Append-only. Newest entries at the bottom. Never edit or delete a prior
  entry — correct a past statement in a new one."

An older reference to `plans/diary.md`, for example in
`plans/static-dispatch-spike-results.md`, points to the old file. To find
the entry, take the date and the time from the heading that the reference
quotes: they start the file name.
