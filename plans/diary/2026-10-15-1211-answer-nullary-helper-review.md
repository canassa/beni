## 2026-10-15 12:11 CEST — Answer nullary helper review

**What I did**

Answered PR #130’s six non-blocking review points. Added private-method
diagnostic ordering coverage, retained hints for local lambda helpers,
and tightened accessor wording to avoid inventing a variable name. The
fifth diagnostic fixture also differs from the saved pre-fix compiler.
Documented the ordering helper’s directory build and unique top-level names.
Opened #131 to reproduce and profile the reported checking overhead separately.

**What I learned**

reachedFunction has only one caller, helperMethod: its same-module lookup
does not change the other call-style hints. A lambda helper stores parameter
patterns on its lambda rather than its declaration, so diagnostics must
look there when naming the actual receiver.
