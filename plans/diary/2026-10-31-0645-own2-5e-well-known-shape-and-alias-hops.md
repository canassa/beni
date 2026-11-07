## 2026-10-31 06:45 CET — own2 5e: the well-known shape and alias hops

**What I did**

- Made the comparison test in `Groups.isComparisonDecl` match the checker's `fitsWellKnown`. Either parameter, and the result, may be a type variable. Before this, `pub eq : T, b → Bool` checked and `==` called it, but v2 accepted its push. That case is now the `ComparisonVariableParam` fixture.
- An importer now takes an alias chain one name at a time (`Prepass.aliasStep`). It applies the first class that a module publishes for a name in the chain. So `Main → Lib.a1 = Mid.a2 → Mid.a2 = priv` applies the class `Mid` publishes for `a2`. That case is the `AliasThreeModules` fixture.
- Raised the line target for `Groups.zig` to 1 930.

**What I learned**

- `Instances.fitsWellKnown` takes the checker's solver state, so own2 cannot call it. I copied its tests instead. When no parameter is an application of a type, the copy takes any type that the module declares as the comparison's type.
