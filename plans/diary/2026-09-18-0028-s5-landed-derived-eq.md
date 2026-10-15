## 2026-09-18 00:28 CEST — S5 landed: derived `eq`

**What I did**

- **S5** (`dd5c58b`). One implementer, one read-only reviewer, one fix pass. The
  derived pass emits every `eq` row per §9 ahead of the declarations; `/=` is
  `!eq`; `Maybe`/`Result` evidence crosses modules; `List.member` takes
  `where a.eq`. M5 R4 measured at −29 % against `c63ae48` (a lower bound: the
  list workloads still bridge through `Basics.eq`). The reviewer found three
  exit-0 miscompiles — a constrained `top`/`ext` in value position emitted a
  wrong-arity call, a private `eq` suppressed the derived row while the
  importer still named it, and `Shapes$Box$eq` collided with module
  `Shapes.Box`'s `pub eq` — plus the `Basics` gap: its own `pub foreign eq`
  and `pub compare` excluded every type it declares from eager derivation,
  so `Order` and `Never` had no rows while uses referenced them. All fixed
  with fail-first fixtures; A.61–A.63.
- `bench/churn.sh` now exits non-zero on a failed compiler spawn instead of
  counting zero rejections; that was the `test-blackbox` flake.
- Wrote the S6 brief from a read-only planning pass (`/tmp/s6-brief.md`,
  contents to be folded into the plan when S6 lands): split into **S6a**
  (derived `compare`, `$order` tables, `Target.ext`/`top` gaining a parts
  range, `List`'s own `eq`) and **S6b** (the core rewrite and the C1 corpus,
  one commit). Decisions: `Dict.empty : Dict k v` is a constant (spec over
  plan); Dict's private helpers keep annotations with explicit `where`;
  `max`/`min` stay `number`; `Dict`/`Set` get no `eq`/`compare` of their
  own — a fixture prints what structural equality answers, for report 19.

**What I learned**

- **A synthesised name must be unspellable.** `<Module>$<Type>$eq` was the
  first emitted name containing the module separator, and a module named
  `Type` under `Module` spelled it too. `$$` is the fix; any future
  synthesised name follows the same rule.
- **§7.1's `Target.ext` has no parts range, and §9.5 needs one.** The table
  cannot express "the `List` module's own `eq`, applied to element evidence"
  inside a derived shape, which is why `List`'s foreign `eq` waits for S6a.
  The body position refused it; the value position did not — the same
  defect surfaced as a diagnostic in one place and a `TypeError` in the other.
- **The module rule bites core exactly where §11 said it would.** `Basics`
  declares `pub compare : number, number -> Order`, so step 1 of §3.3 said
  "`Order` has its own `compare`" and nothing derived. The table must be
  consulted before the exclusion.
- `dispatch/ErrParts` is a pin, not a regression fixture — it passed before
  the change it documents. Say so in the header, or someone will cite it as
  proof.
