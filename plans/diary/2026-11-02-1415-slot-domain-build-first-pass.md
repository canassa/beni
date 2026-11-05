## 2026-11-02 14:15 CET — Ownership v2 on the slot domain: first pass (#1685)

**What I did.** Specified the slot domain in `ownership-v2.md` in place of shapes, κ and lazy views
(§2.2–§2.4, §2.6–§2.12 notes, §3.2–§3.6, §4.1/§4.4 notes, §5, §8 *Q8, the slot domain*), numbering
kept. Built it in `src/own2/`: `Slots`, `Contract`, `Value`, `Relation`, `Eval`, `Resolve`, `Rows`,
`Block` (format 16, validated by re-encoding), and `Groups`/`Ownership`/`Enforce`/`Message` rewired;
the 26 shape/κ/propagate/view/transfer files deleted. Each code (body, lambda, local function) is walked
once; a group is evaluated over its walks' residues until no evaluation read a candidate that moved.
Lambdas, local functions, callbacks (labels, supplies, kept slots, virtual calls for known codes), record
update, `try`, markup, `type_dispatch` and schema references all have rules: nothing is "not built".
Branch `own2-slot-domain`, two commits; not green, no PR.

**Where it stands.** Whole-corpus verdicts against old v2 (2158 roots, `--ownership-everywhere`):
2 928 same, 86 accepted→refused (82 `disjoint` from a callee's instantiated `req`, 3 alias, 1 escaped),
212 refused→accepted, 630 changed ground or detail, 474 demands only old v2 reports and 2 067 only the new
one (it now checks lambdas, callbacks and core's builders), no crash. Core: List's builder loops all
check; `List.unzipHelp`'s two `put` writes are refused `disjoint`. Debug records: `balance` 4 401,
`moveRedLeft` 2 332, generic `removeMin` 120 138 total (growth 24 783 of 65 536, 3 rounds); `rotate` 8
and 15 lists: 2 546 and 7 667 records in 9 and 16 rounds (not linear: rounds re-evaluate, facts are not
delivered along edges yet); the 8-payload-field family reaches `ownership_summary_size`.

**What I learned.** (1) A list of values must not be read through a slice of a growing array across an
append: kids, words and slot runs are now arena allocations. (2) An occurrence asks a callee's whole
separation only at a family slot (`[*]`, `⟲`); asking it at `ε` made every builder loop refuse. (3) The
v1/v2 parity in the corpus keys demands by their text, so the new checker must name one demand per
written route as v1 does, or the known list churns by hundreds of lines. (4) Pending operands must be
filtered by region compatibility: an earlier arm's value waits for its `case` but never runs with a later
arm.
