## 2026-10-26 14:21 CET — block truncation test under a second

**What I did.** Split BlockRead's truncation test (about 1.25 s) into three tests over slices of the prefixes, cut at √⅓ and √⅔ of the length, plus one for the bad magic, version, tag and trailing word. Every prefix is still read, now into one set of tables that each refusal must leave unchanged (#1087).

**What I learned.** Reusing one set of tables saved nothing: the cost is the trial decodes of the prefixes, not the tables' setup. Splitting kept every truncation where sampling by stride would have dropped some.
