# Rust and the price of ignoring theory — organised notes

**Speaker** not named in the paste · **Date** not in the paste (2025 is a guess from the talk's own
references; the directory year is that guess) · **Length** about 52 min
**Video** <https://www.youtube.com/watch?v=1iPWt1gvT_w> · **Transcript** [`transcript.md`](transcript.md)
· **Raw paste** [`raw.txt`](raw.txt)

A prepared, read-aloud argument, not a live stream. The speaker is plainly an advocate of typed
functional programming, category theory and dependent types, and says so; the register is
**polemical** throughout ("a stop gap shot full of holes", "proudly ignorant of a century of
research"). Every time link below goes to the video. The quotes are from YouTube's automatic
captions, lightly corrected, so **quote from the video, not from this file**. The talk is one
person's argument and is never normative for beni. Where a claim is a number or a fact about the
world, the notes say whether the talk supports it.

**Sources.** Papers, posts and code the talk cites or relies on are downloaded in [`sources/`](sources/README.md), with a table of claim, source and status and a list of places where a source differs from what he says.

---

## Thesis

Rust got memory safety by adding a **constraint-solving borrow pass** to a language designed without
regard for type theory, and the price is unsoundness, weirdness, a compiler that is slow, binaries
that are fat, and an ecosystem that bundles. The better route, he says, is **theory first**: regions
for lifetimes, **linearity / graded modal types** (Granule) for ownership, **dependent types** for
bounds, **fusion and recursion schemes** to avoid memory altogether, and an **OCaml-style module
system**. His closing prediction is a "type-directed equational system leveraged for fusion and
automatically optimal memory management" that no language has yet shipped
([51:57](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=3117s)).

The talk has two halves that deserve different weight. **Chapters 1–15** (to 26:00) are a technical
argument about memory and ownership with a worked example. **Chapters 16–27** (26:58 on) are a
critique of Rust's ecosystem, tooling and culture; it is the more polemical part and the least
relevant to a language that targets JavaScript.

---

## The argument, chapter by chapter

### What Rust does — [0:52](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=52s)

Rust brought algebraic data types to the mainstream (he dates them to Hope, 1970s) and made memory
a research topic again; Microsoft and Chromium both found about 70% of their security bugs to be
memory related ([0:46](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=46s)). But Rust "evolved
orthogonally to theory": borrowing is a separate pass that generates and solves constraints, which
he calls a copout. **Type-directed solutions "are simpler, faster, and make better error
messages"** ([1:24](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=84s)) and "if constraint solving
really is necessary in a type system … you've got the wrong idea". The best formal model he knows is
region-based (Oxide); RustBelt's lifetime-subtyping model was abandoned when extended to non-lexical
lifetimes. Regions separate data lifetimes from function lifetimes, so memory can be built and
returned up the call stack ([2:00](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=120s)).
*Unsupported in the talk:* the claim that type-directed is simpler, faster and gives better
messages. He gives no measurement and no comparison.

### Memory management principles, stack, heap, arenas — [3:04](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=184s) to [11:06](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=666s)

A tour of practice. Key line: **memory management is a distinct concern from data transformation and
can be separated** ([5:22](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=322s)). Advice: avoid
pointers and memory; return small structs by value; do not manage small objects by hand; the
x86-64 ABI is poor for structs over 16 bytes. The stack is tied to calls, so it leaks until the
caller returns. The canonical way to use stack well is a **hylomorphism** (an unfold fused with a
fold over an arbitrary functor); quicksort is his example ([6:25](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=385s)).
He wants compilers to "have a built-in understanding of recursion schemes". The heap: `mmap`, `malloc`
as a necessary-but-suboptimal middleman; for the recursive structures (arrays, trees, lists) either
a standard library, a recursion scheme or a bump allocator is ideal
([10:37](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=637s)). *These are standard systems
folklore, stated without sources.*

### Maths vs silicon — [11:06](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=666s)

A language chooses "mathematics or the silicon". **Fusion** "bypasses memory by avoiding
intermediate data", is neglected by silicon-oriented languages, and is "only consistently possible in
pure functional languages leveraging an equational theory". Category theory is "the study of
composition and code reuse". *This is an assertion of taste backed by the fusion claim, which is
true as far as it goes (see the beni section).*

### Garbage collectors — [13:04](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=784s)

Functional languages manage memory with GC; reference counting or tracing, "painfully sub-optimal
and comes with a fat runtime". "It's essentially a skill issue." The most important ignored open
problem is "attaining both principled correctness and optimal performance"
([13:37](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=817s)). *No evidence offered. Compare
beni's `research/55`, which surveys exactly this and finds that the systems with the best answers
(Koka, Lean, Roc) need a reference count at run time.*

### Example of Rust borrowing and lifetime subtyping — [13:56](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=836s)

The one piece of **checkable evidence** in the talk. He walks the well-known unsoundness in Rust's
lifetime subtyping (a function whose type needs `'a: 'b` without writing the bound lets a local
reference be cast to `'static`), "reported to Rust and unfixed since 2015", with a hack for the
reported example and the underlying problem persisting
([15:54](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=954s)). He ties it to contravariance and to
Rust's coercion-site subtyping and trouble at higher rank. The example is real (the rustc issue is
public), though the paste does not name it; his gloss "a priority for over a decade" is his.

### Safe in-bounds access via dependent types — [17:12](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1032s)

"Safety by runtime panic is a funny marketing ploy." A `Vector n` indexed by a `Fin n` makes
in-bounds access correct by construction. Dependent types will "become standard in all
programming"; Rust is "extremely unlikely to gain" them. *A prediction, not an argument.*

### Theory, Granule, linearity — [18:37](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1117s) to [22:44](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1364s)

Borrowing and **linearity form an adjunction**; linearity is the older, better studied half. He
demonstrates **Granule** (graded modal types): a linear value is used exactly once; grades give
exact or interval usage (`dupe` uses its argument exactly twice;
[20:03](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1203s)). Mutable arrays are made safe for
in-place update by hiding them behind a linear API in which the only way to get an array is a
function taking `Array a` at grade one ([20:59](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1259s)).
**Limit he names:** that scheme controls the lifetime of one array and "kills all linearity" when you
want several at once; linear Haskell and Idris have the same irritation and have hacks (phantom
region parameters, `alloc`-beside functions)
([21:26](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1286s)).

### Ownership — [22:44](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1364s)

"Instead of types restricting functions, the flip side is a function restricting its callers." Granule
has a **unique** modality (`*`): a function can demand a provably unique argument. `share` gives up
uniqueness, `clone` deep-copies, and **fractional borrows** (`withBorrow`, `split`, `join`) turn a
unique value into borrows temporarily; `split`/`join` form an isomorphism, mutable borrows have full
access and immutable ones fractions. A complete Granule example splits a unique mutable array in two
and sums the halves concurrently ([24:37](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1477s)).
Identifiers of borrows are existentially quantified. There are **no references to references** in
Granule. He admits Granule did not attempt "an automatic operational interpretation of linearity or
ownership" and that this is "the dark side of theory": incompleteness, waiting for researchers
([26:04](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1564s)). **Do not pass over this concession:**
his positive model is a research language, and the talk itself says it is not yet a practical
alternative to Rust's borrowing.

### Dark side of theory and of pragmatism — [25:31](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1531s)

Compiler authors "take on immense responsibility"; "it is trivial to add things … and nearly
impossible to remove features" ([26:40](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1600s)).
Closest to a design rule in the talk, and it is a general point, not a Rust-specific one.

### Dynamic linking and Security nightmare — [26:58](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1618s), [30:13](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1813s)

Static linking and aggressive monomorphisation "waste space and evict data from the cache" in a way a
single-program benchmark does not show; Swift's resilient layout (witness tables) permits dynamic
linking and a stable ABI with a smaller binary. Bundling is a taboo for package maintainers: a
security fix in a library reaches dynamically linked programs at once and statically linked ones only
when rebuilt. Cargo has a flat namespace, build scripts and proc macros can run arbitrary code, and
CVE/CVSS fit language ecosystems badly. He quotes a paper that vulnerability density per package rises
over time while per line of code it falls, and reads that as memory safety working and packaging
hurting ([34:43](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2083s)). *Mixed evidence: the
package-density quote is a real kind of source; the "32% of exploited vulnerabilities were zero day"
figure is attributed to a name the captions garble, and the cache-eviction argument is asserted
without numbers.*

### Rust miscellaneous advantages — [35:52](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2152s)

A rapid rebuttal of a list of "advantages" (generics, traits, algebraic types, cargo, tooling, memory
and type safety, zero-cost abstraction, minimal runtime, incremental builds, macros, concurrency,
async, error messages, pattern matching). Mostly one-line verdicts. Two with content: **async** is
"two parallel universes of code", every dependency brings a runtime, and "await points are
cancellation sites, so cancel safety is now also a concern"
([39:03](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2343s)); **bounds-checked** safety "degenerates
to runtime panics plus a runtime cost". The list is rhetorical, with no per-item evidence.

### Rust rewrites — [40:09](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2409s)

Discord's Go to Rust gain came from further changes (a B-tree map, a different metrics library, fewer
copies), and ripgrep's gain from a different SIMD algorithm, not from Rust. *Plausible and checkable;
no source is given in the paste.*

### OCaml modules — [41:01](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2461s)

OCaml "has the only correct implementation of a module system": modules and interfaces have a
statically checked many-to-many relation, functors parameterise modules, and a module `N` built on
interface `A` cannot see how `M` implements `A`, so implementations are swappable. Rust tried to
follow and failed, he guesses because "the non-type-directed ownership experiments" made a solid
theory intractable ([42:07](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2527s)). *The first claim is
a strong opinion; the causal guess is stated as a guess.*

### Compilation speed and Runtime speed — [42:26](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2546s), [43:40](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2620s)

"Things that are noticeably slow can't be trusted." Source distribution is the ideal for security and
local optimisation, but its obstacle is compile time; Rust is "right down there with C++", C
compilers are orders of magnitude faster and still not fast enough. Rust matching C by way of LLVM is
"overblown", citing FFmpeg's statement that other languages "do not meet the needs of FFmpeg".
*The FFmpeg quote is a project's stated position, not a benchmark. Compile-time claims have no
numbers.*

### Linux kernel, GPU programming, Personal practice — [44:37](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2677s), [45:25](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2725s), [45:53](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2753s)

Rust in the kernel is not an endorsement (a Linus quote is read as lukewarm). Low-level graphics needs
protocol and cross-device ownership that Rust cannot model and graded types could. **Personal
practice** is the most useful chapter for a compiler author
([46:53](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2813s)): programs are functions; logic lives in
non-recursive pure stepper functions in the style of recursion schemes; memory is "almost always arena
based", the layout is the last thing to work out; hashmaps are one large array; strings are interned
sequentially; "abstract syntax trees for even complete programming languages can be flattened in
memory without … pointers"; "you'd rather have **indices**" than pointers; **struct of arrays beats
array of structs** ([48:12](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2892s)). Resource management
needs linearity; monads were so successful in Haskell because they enforce linear sequencing.

### Conclusion and Future — [49:18](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2958s), [51:57](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=3117s)

Rust's literature lacks the honest comparison and limitations section of academic work. Verdict:
better than C++, unclear versus C, crushed on safety by any typed functional language. Use Haskell and
an FFI for "real safety and performance". Rust "should not be abandoned", but is a "stop gap". Wanted:
a functional language that prioritises performance, with a type-directed equational system for fusion
and automatic memory.

---

## Topic index

| Topic | Where |
|---|---|
| Borrow checking as a constraint pass; type-directed alternative | [0:52](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=52s) |
| Regions (Oxide), RustBelt dropped | [1:36](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=96s) |
| Memory separate from data transformation | [5:22](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=322s) |
| Hylomorphism, recursion schemes; stack use | [6:25](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=385s) |
| Arenas, bump allocation | [9:08](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=548s), [10:37](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=637s) |
| Fusion "bypasses memory" | [11:42](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=702s) |
| Rust lifetime-subtyping unsoundness walk-through | [13:56](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=836s) |
| Dependent types for in-bounds access | [17:12](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1032s) |
| Linearity, Granule grades | [19:51](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1191s) |
| Mutable arrays under linearity; its limit | [20:59](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1259s), [21:26](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1286s) |
| Unique, share, clone, fractional borrows | [22:57](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1377s) |
| "Dark side of theory": no operational story yet | [25:51](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1551s) |
| Cannot remove features later | [26:32](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1592s) |
| Monomorphisation, cache, Swift witness tables | [26:58](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1618s), [28:15](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1695s) |
| Bundling and security patching | [30:13](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1813s) |
| Cargo, build scripts, proc macros | [32:48](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1968s) |
| Async: two universes, cancel safety | [39:03](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2343s) |
| OCaml modules and functors | [41:01](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2461s) |
| Compile speed | [42:26](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2546s) |
| Flat ASTs, indices, struct of arrays | [47:32](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2852s) |
| ABI wishes: more registers, multiple entry points | [48:48](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2928s) |
| Prediction: type-directed equational system for fusion | [51:57](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=3117s) |

---

## What it means for beni

Nothing below is a decision. Each item says what the talk argues, what beni's own documents say, and
where they meet. Where the documents say nothing, the item says "not covered".

### 1. The ownership checker: the talk's positive model is beni's neighbour, not its answer

beni has already taken the decision the talk is arguing around. Lists are plain arrays, "every write
the ownership checker accepts is edited in place", and "a write it cannot prove safe is a compile
error with a `List.copy` fix", on every platform and with **no copying fallback**
([`backend.md`](../../../docs/design/backend.md) §4, *Every platform edits in place*;
[`ownership-checker.md`](../../../docs/design/ownership-checker.md) §30.1).

- **Linearity vs Rust-style borrowing.** The talk's contrast (linearity as the better half of the
  adjunction; Granule's `*` unique modality plus fractional borrows) is a *type-level, annotated*
  approach. beni's checker is neither Rust nor Granule: it is a dataflow pass over BIR after the type
  checker, with an abstract domain of typed paths and cells and per-path liveness
  ([`ownership-checker.md`](../../../docs/design/ownership-checker.md) §0, §2, §4, §7). The demand comes
  from the signatures of `core/List`'s writers, so user code carries no annotation
  ([`research/68`](../../../docs/design/research/68-borrow-checking-and-ownership-survey.md) §1; the
  talk's Granule `Array a` at grade one is the same idea with the annotation written out).
- **Prior art the talk does not mention and beni's survey does.** Research 68 §1 finds that **Clean**
  infers uniqueness and reports violations as errors, and that Rust, Futhark, Swift's noncopyable
  types, Hylo, Idris 2 and **Granule** are in the group that errors but needs modes on signatures
  ([`research/68`](../../../docs/design/research/68-borrow-checking-and-ownership-survey.md) §1–§2). The
  talk's contrast between Rust's inferred-then-checked borrows and Granule's written grades is the
  difference that survey draws.
- **The talk's own limit matches a beni cost.** "Several arrays at once kills linearity"
  ([21:26](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1286s)) is the familiar higher-order and
  aliasing hole; research 68 §1 says that higher-order functions and closures are "the worst place, in
  every system". beni's answer so far is summaries in interfaces and conservative handling, with a
  `List.copy` fix as the escape ([`ownership-checker.md`](../../../docs/design/ownership-checker.md) §16, §30).
- **Regions.** The talk's preferred model is regions. beni's requirements already use a region and
  loan vocabulary for `Ref` ([`ownership-requirements.md`](../../../docs/design/ownership-requirements.md)
  R-5.12.x: a callee "may return an incoming loan-bearing value to its still-live caller region"). I
  read that as an internal device, not as the user-facing model; it is not the talk's tree of data
  lifetimes separated from function lifetimes. I did not trace the full relation.
- **Soundness.** The Rust unsoundness walk-through is a reminder to keep checker claims backed by a
  corpus and an oracle; beni has a Lean oracle for the ownership domain (CLAUDE.md, *The Lean
  ownership proofs*). This is a point of agreement in spirit; the talk adds no technique.
- **What it does not give beni:** a design for the case the talk itself says Granule lacks (an
  automatic operational interpretation of the types). That is the part beni has built, so the talk
  cannot guide it.

### 2. Type-directed vs constraint-based checking: the claim is aimed at borrowing, and beni's checker is constraint-based by design

The talk says needing constraint solving in a type system means "you've got the wrong idea". As
stated that would indict beni's type checker: it generates constraints and solves them with levels,
on Elm's model ([`checker-v2.md`](../../../docs/design/checker-v2.md) §3, *Prior art*;
[`fast-compiler.md`](../../../docs/design/fast-compiler.md) §7), and static dispatch adds *wanteds*
solved by a resolver (`checker-v2.md` §4.2, §9). Two honest readings:

- The speaker's target is **Rust's borrow pass**, which is constraint solving over lifetimes. He does
  not discuss Hindley-Milner unification, which he would presumably accept. So the claim is probably
  narrower than its wording.
- On either reading the claim is **unsupported**: no measurement of "simpler, faster, better error
  messages" is given. beni's performance budgets and error-quality goals are tracked by its own
  harness (`fast-compiler.md` §2, §12), which is the evidence to use.

If anything transfers it is the discipline: beni's ownership pass is deliberately *separate* from
the checker (it reads solved types through one hook, `ownership-checker.md` §2.3), so a rejection
names a cause from a closed list (§8.3) rather than leaking solver state.

### 3. Fusion and recursion schemes: a real gap in the documents I read

The talk's strongest positive claim is that fusion removes intermediate data, is a "massive
optimization", and is possible "consistently" only in pure functional languages
([11:42](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=702s)). beni is a pure functional language with
effect bits known per function.

- **Does beni do fusion?** I found **no list fusion or deforestation pass** in
  [`backend.md`](../../../docs/design/backend.md) §9 or in
  [`research/52`](../../../docs/design/research/52-release-optimiser-state-of-the-art.md). The word
  "fused" in `backend.md` §9 means something else: a function inlined into its one call site
  (*A function called once is written where it is called*; the browser-inline "fused site"). beni's
  loop-shaped optimisations are the tail-call loop (`backend.md` §8), tail calls modulo cons, and
  scalar views over arrays; `foldl`/`foldr` are written in beni (`backend.md` §8, *`foldl` and `foldr`
  leave `foreign`*).
- **The prior art is surveyed, not adopted.** [`research/55`](../../../docs/design/research/55-in-place-update-prior-art.md)
  lists deforestation, `foldr`/`build` short-cut fusion, stream fusion, PureScript's backend-optimizer
  and Futhark's SOAC fusion, and concludes they are pre-codegen IR techniques that "nothing V8 grants
  automatically". It does not decide whether beni should build one.
- **Constraint from rule 8.** Field identity is load-bearing for the UI (CLAUDE.md rule 8); a list
  fusion that rebuilt or reordered record values could not touch the model, but the point should be
  checked rather than assumed.
- **The hylomorphism-in-the-compiler wish** ("compilers … should have a built-in understanding of
  recursion schemes", [7:57](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=477s)) is aimed at stack
  and registers. beni compiles to JavaScript, where there is neither; the benefit would be fewer
  intermediate arrays only. **Not covered** by any beni plan I found, so it is an open design
  question, not a settled one. It interacts with the ownership decision: if lists are edited in place
  once proven unique, many intermediates are already cheap.

### 4. Data-oriented flat IRs: independent agreement, not evidence

The "Personal practice" chapter ([47:32](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2852s)) is nearly
beni's compiler design written as advice: flat ASTs with no pointers, indices instead of pointers,
sequential interning, arena allocation, struct-of-arrays layout. beni's rules are
[`fast-compiler.md`](../../../docs/design/fast-compiler.md) §5: every IR is a `MultiArrayList` with
`u32` indices and a shared `extra` array; no pointer inside an IR; one arena per phase and per
worker; offsets, never slices, into source text; interning. beni took this from Zig itself, Carbon,
rust-analyzer and oxc (§5, citing `01 §1–3`, `04 §2`). The talk is another voice repeating a
design that beni adopted for measured reasons; it adds no new technique. His "entity component system"
aside is a naming point only.

### 5. Compile speed

His "noticeably slow can't be trusted" and "neglecting compilation speeds … is an unwelcome barbarism"
([42:26](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=2546s)) are on-message with beni's thesis and
budgets (`fast-compiler.md` §1–§2: 250k LOC/s checking, 800 ms cold for 100k lines). They are opinion, not
data, and the talk gives no numbers for Rust. Use beni's own comparison harness
([`compare-bench.md`](../../../docs/design/compare-bench.md)) for any claim. Source distribution as an
ideal, which he ties to compile speed, is a package-manager point beni's documents do not take up
(**not covered**).

### 6. Module systems and interfaces

He holds OCaml's modules (signatures, functors, many-to-many interface relation) as the correct model.
beni modules have **no header; `pub` marks the interface**, and the interface hash is a firewall for
incremental builds ([`fast-compiler.md`](../../../docs/design/fast-compiler.md) §3.2 *Modules: no header,
`pub` per declaration*; §8.1; [`language.md`](../../../docs/design/language.md) §1). I found **no functors and no
separately written module signatures** in the language contract. The place beni abstracts over an
implementation is **static dispatch**: a type's methods are the `pub` values of its module, a `where`
clause names the needed method, and evidence is passed at run time
([`static-dispatch-spike.md`](../../../docs/design/static-dispatch-spike.md); `checker-v2.md` §12). That is
closer to Swift's witness tables, which the talk praises at [28:46](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1726s),
than to ML functors; `backend.md` §9 *Whole-program specialisation* is the optimiser's counterpart to
his "multiple entry points / specialise on shape" wishes. The ML-module comparison is a language
question for the owner, **not covered** by a decision sheet I found.

### 7. Dynamic linking vs bundling: little relevance to a JavaScript target

Most of the dynamic-linking and security chapters concern native binaries, shared libraries and the
ELF/PLT, none of which beni has. The nearest beni analogues are output chunking and shared chunks
(`backend.md` §10) and the `foreign` wall that keeps host code out of user hands (CLAUDE.md rule 6).
His package-bundling argument (a library vulnerability reaches bundled copies late) transfers loosely to
a JS ecosystem; beni's package model is not described in what I read for this note. Treat the chapters as
background.

### 8. Where the talk touches other beni decisions

- **No runtime errors** (CLAUDE.md rule 9; the Elm-style guarantee, rule 7): "safety by runtime panic is a
  funny marketing ploy" and the bounds-check critique agree with beni's stance that a failure is a
  typed value or a crash, never a hidden panic. beni's route is total functions and typed results,
  not dependent types. Dependent types do not appear in the language documents I checked, so adopting them
  is not on the table; the talk does not argue otherwise for a language like beni.
- **Effects and resources.** He says monads enforced linear sequencing in Haskell and that session
  types suit synchronisation. beni's route is inferred effect bits and a fiber runtime with `Task.scope`
  and `Task.bracket` ([`transparent-effects-proposal.md`](../../../docs/design/transparent-effects-proposal.md)
  §16–§17). His async critique (cancellation sites, cancel safety) is a fair checklist for that runtime's
  cancellation story; session types are **not covered**.
- **ABI and register wishes** (multiple entry points, passing structs in registers) have no meaning
  for emitted JavaScript.
- **Cannot remove features later** ([26:32](https://www.youtube.com/watch?v=1iPWt1gvT_w&t=1592s)) is consistent
  with CLAUDE.md rules 1 and 2 (specify first; never renumber), but it is a general point.

---

## Caveats

- The speaker is **not named** in the paste and the date is inferred; do not cite the talk by author
  until the video's page is checked.
- The first half contains one checkable technical example and a real surveyed paper; the second half
  is largely assertion and several claims lack sources in the paste ("Vong" statistics, the 20%
  CVE-accuracy figure, ecosystem bloat). Do not use either half to settle a beni decision on its own.
- The positive proposal (graded modal types with an operational story, a fusing, automatically
  memory-managing equational language) does not exist, by the speaker's own account. For beni the
  useful content is the *diagnosis* of where borrowing breaks, the fusion idea as an open optimiser
  question, and the corroboration of the flat-IR design, not the prescription.

Design sections this note draws on: `backend.md` §4, §8, §9, §10; `ownership-checker.md` §0, §2,
§16, §30; `ownership-requirements.md` R-5.12; `research/55`, `research/68`; `checker-v2.md` §3, §4.2, §9, §12;
`fast-compiler.md` §1–§2, §3.2, §5, §7, §8.1; `language.md` §1; `static-dispatch-spike.md`;
`transparent-effects-proposal.md` §16–§17.
