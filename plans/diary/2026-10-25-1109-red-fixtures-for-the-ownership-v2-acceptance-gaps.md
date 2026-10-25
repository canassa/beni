## 2026-10-25 11:09 CET — red fixtures for the ownership v2 acceptance gaps

**What I did.** I wrote a red pending fixture for each row of
`ownership-requirements.md` R-8.2's gap table that v1 does not meet and that had
no fixture (#1006). There are 42 fixture programs under `tests/pending/`,
catalogued as CK-275 to CK-311. Each golden states the required verdict. It is
master's report with only the lines the requirement names changed, so each
fixture is red for that reason alone. Six agents wrote them by area: lists,
records, higher-order, Ref and tasks, entry and sends, and diagnostics. I merged
the `RED` lines and catalogue entries and numbered them in table order. I also
checked that the eleven fixtures already pinned record the reason their
requirements give.

**What I learned.** Seven rows have no red program. Master already meets five
of them: #396's `rt1`, #509's nested pushes, R-4.8.7's `shift`, #279's `where`
alias, and #414, which I could not reproduce. Schema defaults (#228) do not
parse yet. R-6.6 needs a fix-edit field that the diagnostic schema does not
have, and its shape is a design choice. #428 did not reproduce in 12 dumps
under load. Some issues could be closed as met by v1, but nothing in the gated
corpus pins those programs. `comparison_changes_value` is not yet a diagnostic
code, so its fixture uses a `.diag`: a `.codes` file with an unknown code is
malformed.
