## 2026-10-22 14:12 CEST — Copy the dispatch fixture's shared input

**What I did**

Changed the dispatch fixture's doubling operation from `xs ++ xs` to
`List.copy xs ++ xs`. The hidden ownership-everywhere baseline refused the
old expression because the left operand's write overlaps the right operand's
reader. The fixture tests selection of the list append implementation, not
persistent sharing, so copying the written side preserves its purpose.
Updated its dispatch golden and confirmed the fixture checks under the flag.

**What I learned**

The earlier ownership-everywhere script did not traverse the positive
dispatch corpus. The expanded scan found this real sharing on master before
any recursive-function change. A fixture copy resolves it without changing
a compiler check, core, or a platform. Work stays on dagon with self-hosted
builds and no measurements, as required by #210.
