## 2026-10-17 16:13 CEST — make need messages name the function value

**What I did**

- Rewrote the message of a `need` line (issue #272): it says that the function value must return a list it owns, names it as the call writes it (`give`, `r.load`, `tagger`, a lambda's parameter `work` where it said `<function value>`), points at the call that hands it on and at the function that fails (the lambda as written, or the value that carried it here, such as `works`), and asks for a function that returns a list it owns. Before, it said the function changes a list it is handed, and asked for a copy before the change. §28.6 has the amendment; `check/bad/direct/NeedMessage` pins the text.
- Checked the other two messages #272 names. `SchemaConversionShared` is a limit of the checker by §30.10's decision: its schema is built at run time with `Schema.converted`, which keeps the conservative word; the declared form is exact. Its header now says so. A carried lambda's call result no longer says "came from JavaScript" on master: #225's `⊤call` names the call (`NeedMessage`'s `carried` pins it).

**What I learned**

- A plain `⊤` (flavour 0) still comes from several places that are not JavaScript (`markupCallback`, a carried lambda's call with no recorded argument, a capture applied with no closure). No program I wrote reaches them with a rejection, so their text stays until one does.
- `BENI_WRITE_EXPECTED=1` runs the `browser/direct/Api*` pages under Node again, which puts them over the budget; the same pages pass without it. A bless run's budget failures are not findings.
- Deleting single `.zig-cache/o` entries breaks the cache: delete the whole cache.
