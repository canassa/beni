## 2026-10-15 10:25 CEST — split the diary into one file per entry

**What I did**

Issue #123: `plans/diary.md` became `plans/diary/`, one file per entry,
named `YYYY-MM-DD-HHMM-<slug>.md`. A script split the 224 entries and
checked each file against its entry: the text is the same, and only the
blank lines at the end of each entry are gone. The 26 headings of
2026-09-24 to 2026-09-27 have no time, so their names take the time of the
commit that added them; each of those commits is on the heading's day. No
two names collided. `CLAUDE.md`'s *Captain's log* now asks for a new file
per entry, `plans/diary/README.md` holds the convention and the history,
and the research reports and resume notes point at the new files. This
entry is the first one written as its own file.

**What I learned**

The old file was in merge order, not in time order: 83 of the 224 entries
sort to a new place by the time in their headings, most of them entries
that a branch wrote before another branch merged. The diary also held two
stray `|||||||` lines from hand-merged conflicts, which is the failure the
split removes. Every open branch on 2026-10-15 conflicted in this one file
after each merge, and GitHub runs no workflow on a pull request that
conflicts, so no CI ran on any of them until a rebase.
