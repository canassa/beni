## 2026-09-22 16:11 CEST — Schema field docs and primitive alias literals

**What I did**

Delegated two independent fixes to Sol agents and reviewed their changes. Schema
field docs now occupy their own line at the ordinary field column; updated the
§2 contract and one formatter fixture/golden, including mixed plain/doc comments
and arbitrarily indented input. Fixed queue row 67 by checking a constrained
variable against the alias root in `unifyAlias`. Added the fail-first
`check/good/NumericAliasLiterals` project covering local/imported Int and Float
aliases, chains, both operand orientations, record controls and interface names.
The baseline produced six kind_mismatch diagnostics; the fixed compiler checks
cleanly and matches the interface golden. The combined `zig build test`,
`zig build test-blackbox` and `zig build fmt-check` gates all passed.

**What I learned**

The alias defect also rejected appendable String aliases: the same wrong-root
check caused both failures, and the fixture pins both without changing the kind
lattice. Moving field docs must canonicalize already separate docs as well as
inline ones; AST preservation, comment order and formatter idempotence pass.
Q7's constructor-pattern spelling still needs owner confirmation before S2.
Schema-containing inputs remain excluded wholesale from resolver fuzz during S1;
removing that exclusion is now explicit in S2's contract and queue acceptance.
