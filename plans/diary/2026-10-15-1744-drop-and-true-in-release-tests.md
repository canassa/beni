## 2026-10-15 17:44 CEST — drop `&& true` in release tests; research 102 items 1, 5, 7

**What I did**

- Item 7 of research 102: the release peephole (`Spec.peephole`) now writes `x && true` and
  `x || false` as `x` in a test position. Specialisation leaves `f===c.fail&&true` at every
  field of a compiled schema reader once it folds `!c.all`. Conduit release brotli: tea
  31,745 → 31,609 (−136), direct 38,243 → 38,175 (−68). `bench/size.mjs`: release gross −76,
  pages and development output unchanged. `bench/schema-libraries`' beni builds are
  byte-identical, because a `--library` build keeps `!c.all`. Amended `backend.md` §9,
  *Compact statements*, item 3. New fixture `emit/release/app/SchemaReaderTest`, which the old
  compiler fails: it emits four `&&true`.
- Item 1 (request bodies through compiled `print`): I prototyped a general design and then
  handed it over when the manager moved the item to the schema redesign. The design adds an
  `Engine` on the schema box (`Interpreted | Declared`), makes core/Schema's `Interpreted` the
  one core constructor that guards, and adds a guarded `root` schema member. The handover note
  and partial diff are in the session scratchpad. Nothing of it was committed.
- Item 5 (`Http.track`'s streamed body only when reachable): stopped, not built (below).

**What I learned**

- Item 5 cannot be done exactly with today's reachability. Conduit calls `Http.request` with
  `tracker = Nothing`. `request` turns that `Maybe` into `Reading` (`Just f → Tracked f`), and a
  core constructor never guards (`backend.md` §9). So `Tracked` and the chunked reader are
  reached whenever `request` is. Gating on `Http.track` is also wrong: `request`'s tracker is a
  function that needs the stream without any `track`. For `send`, dropping the tracked path
  without `track` would change when the result arrives (`ready`, `yieldNow`, one hop per
  chunk). An exact fix needs either an API change or a compiler fact. The API change is a
  platform type for the tracker, such as `Maybe Tracker` built by an `Http` function, so that its
  constructor guards. The compiler fact would let a constructor-valued record field act as a
  constant. Both are the owner's decision.
- The `&&true` literal is not only in schema readers. The direct runtime's `if(b.it!==c||false)`
  and `if(D(a)&&true)` went too; that is why 122 run-hash files were re-recorded, 79 of them direct pages.
