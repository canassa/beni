## 2026-10-24 00:32 CEST — a via extractor may be a beni declaration

**What I did.** #883, the compiler feature `Html.js`'s move needs (#877): a vocabulary event's
`via` may name an annotated beni declaration as well as a `foreign`. The checker reads the scheme
from the annotation either way (`check/Vocab.zig`), with two messages for the two refusals (no
annotation; no such value); reachability keeps a non-`pub` beni extractor as it kept a `foreign`
one (`js/Reach.zig`). Spec first: `checker-v2.md` §25.2 and §25.8, `boundary.md` §9.3,
`language.md` §11.14. Fixture `browser/dom/BeniVia`: two beni extractors over `Js`, one `pub`,
one not; red before (the row is refused and `onProbe` falls to the wildcard attribute),
green after. `check/bad/core/VocabularyTypes` keeps its `via` case as an unannotated value.

**What I learned.**
- `e` is a prelude value (Euler's number), so a parameter named `e` is `shadowing`; the
  siblings' convention of not calling the event `event` (a window global the minifier keeps) does
  not carry to beni, where `ev` is the short name that is free.
- A platform's vocabulary fault reaches the program as a type mismatch on the wildcard attribute
  `"*"`, because the refused row is left out and the name resolves to the attribute: older than
  this change, worth a message of its own some day.
- A `check/bad/core` golden is the exact stderr of `beni check --diagnostics=json --core
  --root=<dir> <file>`, so a one-message change can be regenerated without the corpus run.
