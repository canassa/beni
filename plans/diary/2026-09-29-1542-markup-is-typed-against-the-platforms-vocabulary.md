## 2026-09-29 15:42 CEST — markup is typed against the platform's vocabulary

**What I did**

- Built checker-v2.md §25.3–§25.7 and §25.9: a module that writes markup is typed instead of
  stopped. A per-module view of the vocabulary resolves tags and attribute names (exact, then the
  most specific pattern; element-scoped before unscoped), reading the vocabulary module's published
  rows, or its own checked declarations when the vocabulary module writes markup itself.
- Six obligation kinds ride on their variables as `interpolatable` does — `renderable`, `handler`,
  `attr_form`, `row`, `key` and `item` (primitive-`eq`, which also raises `unkeyed_for`) — and take
  their boundary rule at step 3 with `try`'s defaults, since three of them unify. What the syntax
  and the rows decide alone is a fault node the solver reports, so it lands on the right
  declaration.
- Components are typed as the call they mean: a `call` node at the callee, a closed record or a
  record update over the spread, `children` interned by the graph.
- The dispatch table gained a markup section (format 5, cache entry 5) and `dump --stage=dispatch`
  prints it. `build` refuses a surviving markup root with `unknown_markup_lowering`.
- The owner's refusal of quoted `on…` attribute names is a new code, `untyped_event_attribute`.
  `markup_type_in_foreign` compares each platform's own lowering with the build's, which the graph
  now carries; the cache key of a platform module with a `foreign` includes both.
- Fixtures: a `markup/` flag directory runs check and dispatch fixtures under `--platform=html`.
  One `check/bad` per diagnostic, the typeahead and the list/row forms as dispatch goldens,
  components across modules, two `build/bad`; blackbox scenarios for warm vs cold, `--jobs`, the
  dispatch round trip and a reversed declaration order.

**What I learned**

- A lambda of the wrong arity leaves its parameters unbound, so the "cannot tell" default of a
  hole inside it said a second thing about one mistake; the default now stays silent in a
  declaration that already failed.
- A module's `check` given a single file does not see a sibling module; a two-module blackbox
  project must be checked as a directory.
- `src/check/rules_test.zig` holds every checker file to 1 500 lines and lists every file by name,
  and it forbids reading a type's children outside `Walk`: the category sentences moved to
  `MarkupTexts.zig` and field lookups go through `Walk.fieldIn`.
