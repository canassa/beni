## 2026-11-05 20:29 CET — closures, steps no place names, and a later function

**What I did.** #2052: what an escaped closure runs in turn escapes too (#2041). #2054: a step a place cannot name is `⊤`, and a schema member in a template a `var` place (part of #2043). #2060: a read past an argument's fold reads what is there (#2047). #2061: a supply asks a function a row runs later apart (#2050). Filed #2053, #2056, #2057, #2058, #2059, #2062.

**What I learned.** An empty reading of a contract means fresh to a caller: every lost slot is a hole. An open row is the deepest of them, and #2057 needs a real slot: as `var` it refuses 17 positions master accepts. My oracle read a panic as a refusal until a review caught it: it now prints CRASH. A filter on "FAIL" lines in a gate loop missed a failing table count: check the exit, or every error line.
