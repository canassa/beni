## 2026-10-31 06:36 CET — own2 5e review: comparison aliases and the signature test

**What I did**

- Fixed the two defects that the review of #1437 found.
- A comparison can be written as an alias (`compare = helper`). It escaped R-5.13.1, because the alias was not walked and `helper` was walked as an ordinary function. `Groups.comparisonWalks` now walks the target of each comparison alias in the same module as the comparison. A comparison alias whose target is in another module is walked and stays unbuilt at the name, as on master.
- A private `compare : T → List Int` was refused as a comparison. The test is now the checker's well-known signature: two parameters of a type that the module declares, and a `Bool` or `Order` result.
- A `pub` alias now publishes the class of its target, so an importer can apply it when the target is private. An importer first applies the entry for the alias, then the class of the function at the end of the chain.
- New fixtures: `ComparisonAlias`, `ComparisonAliasImported` and `ComparisonNameOnly`. Six new known entries. No other fixture changed.

**What I learned**

- A comparison alias with a target in another module cannot write the comparison's type unless the target is polymorphic, because a module that declares `T` cannot be imported back by a module that names `T`. Leaving that case unbuilt costs nothing in practice.
- `ComparisonNameOnly` passes on master. It is a guard against this PR's first commit, which failed it.
