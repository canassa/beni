## 2026-10-24 01:28 CEST — a tag no run tells from a failure

**What I did.** One item of #916: the dead Tick/Notify decode at N = 1. `SchemaValid.deadTags`
finds a schema the module does not expose, that nothing else refers to, whose every run is the
scrutinee of a `case`. A variant whose only arm gives the very reference the `Err _` arm gives
is dead: its validator worker and its shape read its tag as unknown, and `Lower.planCase` leaves
its arm out. Spec: `schema.md` §6, amended. Fixtures, red first: `run/SchemaDeadTags` and
`run/SchemaDeadTagsShapes` (outputs unchanged), `emit/release/app/SchemaDeadTags` and
`SchemaDeadTagsShapes`. No other golden moved.

S1 (one-file brotli, my build): N = 1 −59, −59 and −60 B over seeds 1–3. At N = 16 −48, −19 and
−65. At N = 64 seed 1 grew 93 B on 89 fewer raw bytes that are exactly the deletions; seeds 2 and
3 fell. I also measured two of #916's estimates and dropped them, since both grew the output: an
entry registered with its whole row in place of `[c[0],c[1],c[2]]`, and `?0:1` toggles written
as booleans, in two forms.

**What I learned.** Brotli prices repeated longer forms below unique short ones. Each estimate
that was not measured on the real output was wrong in sign here. The equality the dead-tag rule
needs is very narrow: the same instruction data for a `local` or a `top`. Even so it takes the
case S1 has, because the arms say `model`.
