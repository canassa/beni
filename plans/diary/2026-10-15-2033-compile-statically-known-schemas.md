## 2026-10-15 20:33 CEST — compile statically known schemas (schema slice A)

**What I did**

- Wrote the owner's design into the spec. It goes in `schema.md` §6, *A statically known schema
  runs compiled*, with A.11 and an *As built — slice A* note in §16. `boundary.md` §9.8.12 and
  `backend.md` §9 point to it. Every schema the program fixes at compile time runs compiled, and
  the library interpreter is the test oracle.
- Built it in `core/Schema`. A schema value carries an `Engine`:
  - `Interpreted`, which only `box` makes;
  - `Compiled`, which holds a declaration's workers, or what a compiled maker (`list`,
    `nullable`, `converted`, a primitive) was `Made` of.

  `parse` and `print` run the workers. `S.schema` is a fourth reachability member, `root`. It
  reaches the description and each direction only through guards. `Reach` decides the
  constructors of `Engine` and `Made` like a program's own.
- Kept `Http`'s API. `Http.jsonBody (X.schema ⊤)` and `Http.expectJson (Schema.list X)` now print
  and parse compiled.
- Added a `.compiled-schemas` corpus marker. It holds Conduit and 12 schema fixtures to shipping
  no `Schema$run` or `Schema$box`.
- Added `run/SchemaComposed`, whose golden equals master's interpreter output, and
  `browser/tea/HttpJsonList`, which carries the typed `UnprintableBody`/`BadBody` issues at list
  paths.
- Conduit release brotli: tea 31 497 → 28 893, direct 36 502 → 33 906.
- Opened #175 (decode/encode/read/write workers), #176 (the cost to dynamic-schema programs) and
  #177 (unused root wrappers).

**What I learned**

- A runtime engine tag, together with reachability's constructor guards, gives a compile-time
  guarantee and needs no call-site specialisation. The schema travels with its compiled code
  through any variable or helper.
- Each worker has to be made where a root runs, not where the schema is composed. Before that
  change, any program that used a primitive shipped every core worker. Static reachability cannot
  tell a closure that is made apart from a closure that is called.
- Release once-inlining must treat `core/Schema`'s exported private values as `named`, as it
  already treats `core/List`'s. Otherwise a `--library` build exports a name it never declares.
  The bench's `--schema-library` build found this.
- The host was at load 12–37 for most of the session. The A/B on the unchanged declaration path
  was noise, ±10–40% both ways. The claim of no slowdown therefore rests on the workers being the
  same bytes. The schema-value path's 7–65% gain held across runs.
