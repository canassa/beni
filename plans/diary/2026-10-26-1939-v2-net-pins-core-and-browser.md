## 2026-10-26 19:39 CET — The v2 net pins core and browser/

**What I did.** I answered #1107's review. Core's unchecked declarations are a committed golden, and a core limit fails. Every browser/ page joins the parity (+3 s wall). Known keys carry an occurrence index. A bare-variable parameter written through an alias (`type alias Id a = a`) now reads deep. `HeldIntoTypeVariable.beni` pins two beni wrappers that flip at S3b. I added a red proof for each change.

**What I learned.** `browser_test` runs the corpus harness on corpora in temporary roots. A whole-corpus net keyed to repository paths must run only on the repository's own root (`Config.v2Net`), or the harness's own tests fail on goldens that cannot exist there.
