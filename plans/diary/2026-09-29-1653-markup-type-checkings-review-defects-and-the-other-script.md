## 2026-09-29 16:53 CEST — markup type-checking's review defects, and the other script sinks

**What I did**

- Catalogued CK-215 to CK-220 with red fixtures on the base, then fixed and promoted each.
  A `let` generalised the message variable of markup whose handler, hole or `For` row named an
  enclosing parameter, so `Html Other` passed as `Html Msg`: those obligations now have the
  message variable, payload and item as dependants, held at the owner's rank like a
  `tuple_index`'s result (`ordering_test.zig` swaps the `let`'s bindings).
- `markup_type_in_foreign` now walks records and custom types (a `holds_markup` fixpoint beside
  `has_function`, in the dependency digest) with no budget; the fixpoint moved to `TypeFacts.zig`
  for the 1 500-line rule. A component's markup children get their own message variable, per the
  plain-call equivalence, with a `children`-naming message when the field takes no markup.
- Dependency platform names must be one plain directory name, unique in the chain; nameless
  dependencies take their directory's last segment. Element attribute duplicates fold case.
- Diagnostics: markup too deep for the generator is worded for markup and poisons what it did not
  read; `unkeyed_for` suggests a field the item has; `unknown_form_attribute` has its own title; a
  non-keyed `Show` is shown its own `case`; a hole whose expression stops short skips to its `}`.
- The owner's MD39: `invalid_attribute_name`, `untyped_srcdoc_attribute`, a `url` bit on escapes
  in the markup section (dispatch and entry formats 6), and no `script` in `html`.

**What I learned**

- The checker's obligation table already had the right tool — dependants lowered to the owner's
  rank — and the markup rows simply declared none; the generalisation bug was a missing column
  entry, not missing machinery.
- A hole's recovery that skips to its `}` exposed an error a sibling hole had been hiding
  (`MarkupEllipsisElsewhere`), which is the recovery working, not a regression.
