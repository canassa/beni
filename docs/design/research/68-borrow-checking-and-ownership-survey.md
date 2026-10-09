# 68 — Borrow checking and ownership in functional languages: a survey

Status: first-pass literature and prior-art survey, breadth over depth, 2026-10-09.
Nothing here is normative. Written for the owner's question: could beni make it a
compile error to edit a `List` while something else still holds the old version, so
every list can be a plain, in-place-updated JS array and sharing needs an explicit
`List.copy`?

Verification note. Items marked **[unverified]** were written from memory and not
confirmed against the source in this pass. Several links are canonical landing pages
or DOI/arXiv identifiers given from memory; check before citing. Only the Perceus,
FP², Counting Immutable Beans, Futhark uniqueness, mutable-value-semantics and OCaml
modes entries were confirmed by a search in this session.

## 1. Summary: what the field says

Yes in principle, with a precise price tag. A pure language has no hidden mutation, so
the *only* alias question is "does anything still reach the old value after this
update?", which is a liveness plus reachability question, much easier than Rust's
(no interior mutability, no `&mut` handed to callees that keep it, no lifetimes in
data). Within one function a last-use analysis is exact and cheap. The field splits
sharply on what happens at function boundaries and inside data structures:

- **Systems that report a violation as an error** (Clean, Futhark, Rust, Linear
  Haskell, Idris 2, Mercury unique modes, Koka's `fip`, Swift noncopyable types,
  Austral, Mojo, OCaml `unique` mode) *all* put a mode on function signatures
  (`*` / `owned` / `consume` / `linear` / `fip`) and on types that can hold values.
  None of them infers that fully and also reports errors on the inferred result. Where
  inference exists (OCaml modes, Lean borrow inference, Roc/Morphic, Koka Perceus) it
  drives *optimisation*, and imprecision costs speed, not correctness.
- **Systems that infer** are all silent-fallback: when uniqueness cannot be proved the
  runtime copies (Swift CoW, Roc, Lean `Array`, Koka). Those have the well-documented
  "performance cliff": one accidental extra reference turns an O(1) update into an
  O(n) copy with no diagnostic. Koka's `fip`/`fbip` keywords and Swift's noncopyable
  types exist to turn that cliff back into a compile error, and they pay for it with
  annotations and restricted code.
- **No mainstream pure language makes "list still referenced elsewhere" an
  inferred, annotation-free error.** The nearest are Futhark (arrays only, uniqueness
  in signatures, errors on use-after-consume) and Clean (uniqueness inferred for
  local code, declared in signatures, errors reported). Both are the owner's proposal
  restricted to one type or one annotation discipline, and both are in production use
  for years, which is real evidence it is workable.
- Precision is lost at: higher-order functions and closures (a captured list is an
  alias), polymorphism (`a` may or may not be unique), containers (a record or `Maybe`
  holding the list; "unique container of shared elements" vs the reverse), recursion
  and mutual recursion (modes need a fixpoint or annotation), conditional consumption
  (`if` where one branch keeps the old value), and partial application / `_` holes.
  Rust's well-known false positives (NLL problem case #3, conditional returns of
  borrows, disjoint-field borrows through method calls) are exactly the
  flow-sensitivity and callee-contract limits, and Polonius is the long attempt to
  close them.
- Soundness asymmetry matters for beni. Compiled to a plain JS array with no
  refcount, a *missed* alias is a silent wrong answer, so the checker must be sound and
  every imprecision surfaces as a false-positive error the user must work around with
  `List.copy`. That is the Rust experience, mitigated if the checker is flow-sensitive,
  inferred, and reports in Elm-quality prose. Beni's CLAUDE.md rule 7 ("guarantees, not
  restrictions") points toward: error where a wrong answer is possible, but an
  escape hatch (`copy`) always available and false positives measured.

Honest bottom line: a *sound, inferred, whole-program-precise* checker is research-grade
(Section 6 questions); a *signature-annotated or mostly-inferred* checker in the
Futhark/Clean/OCaml-modes mould is proven engineering. A conservative variant (error
only on a simple, local, explainable pattern; copy elsewhere) is the cheapest start.

## 2. Languages that implemented ownership, uniqueness or linearity

Errors on violation (static, user-facing):

- **Rust** — ownership, borrowing, lifetimes (inferred within bodies, declared at
  boundaries), NLL, two-phase borrows, reborrowing. https://doc.rust-lang.org/book/ch04-00-understanding-ownership.html ; NLL RFC https://rust-lang.github.io/rfcs/2094-nll.html ; Polonius https://rust-lang.github.io/polonius/ ; known limit "problem case #3" is in the NLL RFC.
- **Clean** — uniqueness types (`*` on types), used for safe in-place I/O and arrays; uniqueness inference for locals, `*` in signatures; use-after-consume is a compile error. https://clean.cs.ru.nl/Clean **[unverified URL]**
- **Futhark** — uniqueness types for arrays only; `*[n]t` parameters are consumed; in-place `with` update; use of a consumed variable or its alias is a compile error; alias tracking is part of the checker. https://futhark-lang.org/blog/2022-06-13-uniqueness-types.html ; error index https://futhark.readthedocs.io/en/stable/error-index.html
- **Linear Haskell** — `a %1 -> b` arrows, backwards compatible, linear-base library. https://arxiv.org/abs/1710.09756
- **Idris 2** — quantitative type theory, multiplicities 0/1/ω on binders. https://arxiv.org/abs/2104.00480
- **ATS** — linear types and proofs for safe pointers/arrays; heavy annotation. https://www.ats-lang.org **[unverified]**
- **Mercury** — unique and mostly-unique modes (`di`, `uo`), compiler checks them; compile-time garbage collection / structure reuse work. https://mercurylang.org **[unverified]**
- **Cyclone** — region annotations, unique pointers (`*`), borrowed/`@`-regions; direct ancestor of Rust. https://cyclone.thelanguage.org **[unverified]**
- **Mezzo** — permissions as types, ML-like, aimed at aliasing/mutation control. http://protz.github.io/mezzo/ **[unverified]**
- **Austral** — linear types with a small borrow construct; designed for simple, fully explainable checking. https://austral-lang.org
- **Pony** — reference capabilities (`iso`, `val`, `ref`, `box`, `trn`, `tag`) for data-race freedom. https://tutorial.ponylang.io/reference-capabilities/
- **Swift** — value semantics by copy-on-write (runtime uniqueness check), plus `borrowing`/`consuming`/`inout`, `~Copyable` noncopyable types, `consume` operator. Ownership manifesto https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md ; SE-0377 and SE-0390 on swift-evolution.
- **Mojo** — `read` / `mut` / `owned` argument conventions, lifetime inference, `^` transfer. https://docs.modular.com/mojo/manual/values/ownership
- **Hylo (Val)** — mutable value semantics: `let`/`inout`/`sink`/`set` parameter conventions, no references in the language, no lifetimes; whole-program value semantics with static checking of exclusive access. https://www.hylo-lang.org ; papers in Section 5.
- **Koka** — Perceus precise RC plus reuse; `fip`/`fbip` function modifiers turn "must be in-place" into a compile error (checked, with `fip(n)` allowing n allocations). https://koka-lang.github.io/koka/doc/book.html
- **OCaml (OxCaml, Jane Street)** — modes `local`, `unique`, `once`, `portable`, `contended`; locality and uniqueness are *inferred* modes, fully backwards compatible. https://blog.janestreet.com/oxidizing-ocaml-ownership/ and /oxidizing-ocaml-locality/
- **Granule** — graded modal types (linearity, security levels, etc., via grades). https://granule-project.github.io
- **Verona** — region-based ownership ("cowns", regions as tree-shaped ownership) for concurrency. https://github.com/microsoft/verona **[unverified]**
- **Lobster** — compile-time ownership *inference* by flow analysis, no annotations, falls back to RC; closest in spirit to an "inferred, user-invisible" system. https://strlen.com/lobster/ and Aardappel's "Memory Management in Lobster" page **[unverified]**
- **Vale** — generational references plus regions and "pure" blocks that borrow immutably; an alternative to a borrow checker. https://vale.dev
- **Inko** — single ownership with *runtime* checked borrows (a violation is a panic, not a compile error). https://inko-lang.org **[unverified]**
- **Carbon / Cpp2** — C++ successors; Cpp2 has parameter kinds `in`/`inout`/`out`/`move`/`forward` and last-use move inference. https://github.com/hsutter/cppfront (parameter kinds, "definite last use") **[unverified]**
- **Ante** — shared/owned types with inferred lifetimes aimed at a high-level language. https://antelang.org **[unverified]**
- **Nim ARC/ORC** — move inference at last use, `sink` params, copy otherwise (silent). https://nim-lang.org/docs/destructors.html **[unverified]**

Inference with silent fallback (perf only):

- **Lean 4** — precise RC; destructive update when RC=1; automatic *borrow inference* for parameters plus `@&` manual annotation; `Array` updates silently copy if shared. Paper in Section 5.
- **Roc** — RC, automatic in-place updates when unique, Morphic alias analysis for mutation specialisation (refcount checks remain for what cannot be proved). https://www.roc-lang.org ; Morphic: William Brandon et al. **[unverified]**
- **SAC (Single Assignment C)** and **Sisal** — functional array languages; sisal's "copy elimination", SAC's reference counting plus update-in-place analysis and "non-destructive" reuse. https://www.sac-home.org **[unverified]**
- **Haskell (GHC)** — no general update analysis; `ST`/`runST`, `MArray`, and Linear Haskell's `linear-base` are the user-level answers; thawing/freezing with unsafe variants. Local mutation behind a pure interface (`runST`) is a different, simpler route to the same goal (see Section 7).

## 3. Theory and type systems

- **Linear logic** — Girard 1987, "Linear logic", Theoretical Computer Science 50. https://doi.org/10.1016/0304-3975(87)90045-4
- **Linear types can change the world!** — Wadler 1990; linear types give in-place update and I/O without monads. https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html
- **Affine vs linear vs relevant**; structural rules (contraction, weakening, exchange); survey: Walker, "Substructural Type Systems", ch. 1 of *Advanced Topics in Types and Programming Languages* (2005). **[unverified]**
- **Uniqueness vs linearity** — linearity says a *use* count (this binder is used exactly once); uniqueness says a *reference* property (this is the only reference to the value; may be used many times, but only unique things can be updated). Clean's uniqueness is a guarantee about the past of the value, linear is an obligation on its future. Reconciled by **Marshall, Vollmer, Orchard, "Linearity and Uniqueness: An Entente Cordiale", ESOP 2022**. https://doi.org/10.1007/978-3-030-99336-8_13 **[unverified link]**
- **Barendsen & Smetsers 1996, "Uniqueness Typing for Functional Languages with Graph Rewriting Semantics"**, Mathematical Structures in CS 6(6). Clean's type theory. **[unverified link]**
- **Region-based memory management** — Tofte & Talpin, POPL 1994 and "Region-Based Memory Management", Information and Computation 1997; MLKit implementation. https://doi.org/10.1006/inco.1996.2613 ; https://elsman.com/mlkit/
- **Walker & Watkins, "On Regions and Linear Types", ICFP 2001** — regions via linear capabilities. **[unverified link]**
- **Alias types** — Smith, Walker, Morrisett, ESOP 2000. **[unverified link]**
- **Fractional permissions** — Boyland, "Checking Interference with Fractional Permissions", SAS 2003. **[unverified link]**
- **Separation logic** — O'Hearn, Reynolds, Yang 2001; Reynolds 2002. https://www.cs.cmu.edu/~jcr/seplogic.pdf **[unverified link]**
- **Ownership types** — Clarke, Potter, Noble, "Ownership Types for Flexible Alias Protection", OOPSLA 1998. **[unverified link]**
- **Capabilities** — Pony's deny capabilities (Clebsch et al., AGERE 2015, "Deny Capabilities for Safe, Fast Actors") **[unverified]**; Gordon et al., "Uniqueness and Reference Immutability for Safe Parallelism", OOPSLA 2012 (Microsoft, C# isolated/immutable) **[unverified]**.
- **Quantitative / graded types** — McBride, "I Got Plenty o' Nuttin'" (2016); Atkey, "Syntax and Semantics of Quantitative Type Theory", LICS 2018; Orchard, Liepelt, Eades, "Quantitative Program Reasoning with Graded Modal Types", ICFP 2019 (Granule). **[unverified links]**
- **Usage analysis / "Once upon a polymorphic type"** — Wansbrough & Peyton Jones, POPL 1999; inference of use-once for GHC. **[unverified link]**
- **Generic usage analysis with subeffect qualifiers** — Hage, Holdermans, Middelkoop, ICFP 2007; an inferred uniqueness/usage analysis. **[unverified link]**
- **Mode inference** — Lindley et al. on mode inference for OCaml's modes. https://homepages.inf.ed.ac.uk/slindley/papers/mode-inference.pdf
- **Mode crossing** (types that ignore modes, e.g. `int` is always shareable) — Peters et al. https://people.mpi-sws.org/~bpeters/papers/mode-crossing.pdf

## 4. Static analyses without types, inferred by the compiler

- **Aggregate update problem** — Hudak & Bloss, "The Aggregate Update Problem in Functional Programming Systems", POPL 1985; Bloss, "Update Analysis and the Efficient Implementation of Functional Aggregates", FPCA 1989 — the foundational "can we update this array in place?" analyses, built on abstract interpretation of sharing/liveness. **[unverified links]**
- **Sisal / OSC** — Cann, "Compilation Techniques for High Performance Applicative Computation" (LLNL, 1989): build-in-place and update-in-place analysis, copy-elimination results. **[unverified]**
- **Escape analysis** — Choi et al., "Escape Analysis for Java", OOPSLA 1999; Park & Goldberg, "Escape Analysis on Lists", PLDI 1992 (functional lists, directly relevant). **[unverified links]**
- **Sharing/aliasing analysis for lazy and strict functional languages** — Jones & Le Métayer, "Compile-time garbage collection by sharing analysis", FPCA 1989; Mohnen on compile-time GC and sharing. **[unverified]**
- **Mercury compile-time GC** — Mazur, Ross, Janssens, Bruynooghe, "Practical aspects for a working compile time garbage collection system for Mercury", ICLP 2001. **[unverified]**
- **Liveness / last-use** — the dataflow behind Rust NLL, Cpp2's definite last use, Nim move inference, Perceus's borrowed-until-last-use. Precise intraprocedurally, needs callee summaries across calls.
- **Perceus reuse analysis** — pairs a pattern match's dropped constructor with a same-size allocation in the branch ("reuse token") and uses a runtime uniqueness test. Static part is local; uniqueness is dynamic.
- **Morphic (Roc)** — whole-program interprocedural alias analysis specialising mutation; see Roc compiler `crates/compiler/` and the Morphic repo. **[unverified]**
- **Lean borrow inference** — heuristic marking of parameters as borrowed when not consumed or returned; inferred per function, iterated to a fixpoint on mutually recursive groups. Paper in Section 5.
- **OCaml mode inference** — constraint-based inference of unique/local on bindings; modes appear in types only at function arrows.
- **Rust borrowck** — liveness-based region inference (NLL), location-sensitive in Polonius via Datalog.

## 5. Key papers

| Paper | Authors | Year | Contribution | Link |
|---|---|---|---|---|
| Linear types can change the world! | Wadler | 1990 | Linear types give pure in-place update and I/O. | https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html |
| Linear logic | Girard | 1987 | The logic behind all of this. | https://doi.org/10.1016/0304-3975(87)90045-4 |
| The aggregate update problem | Hudak, Bloss | 1985 | Defines the problem; sharing-analysis answer. | **[unverified link]** |
| Uniqueness typing for functional languages with graph rewriting semantics | Barendsen, Smetsers | 1996 | Clean's uniqueness type theory. | **[unverified link]** |
| Implementation of the typed call-by-value lambda-calculus using a stack of regions | Tofte, Talpin | 1994 | Region inference; stack discipline from types. | **[unverified link]** |
| Region-based memory management | Tofte, Talpin | 1997 | The full region calculus and soundness. | https://doi.org/10.1006/inco.1996.2613 |
| Region-based memory management in Cyclone | Grossman et al. | 2002 | Regions plus unique pointers in a C dialect. | **[unverified link]** |
| Once upon a polymorphic type | Wansbrough, Peyton Jones | 1999 | Use-once inference with polymorphism. | **[unverified link]** |
| A generic usage analysis with subeffect qualifiers | Hage, Holdermans, Middelkoop | 2007 | Usage analysis, one framework, inferred. | **[unverified link]** |
| Futhark: purely functional GPU-programming with nested parallelism and in-place array updates | Henriksen et al. | 2017 | Uniqueness types (arrays) in a pure compiled language. | **[unverified link]**; blog https://futhark-lang.org/blog/2022-06-13-uniqueness-types.html |
| Linear Haskell: practical linearity in a higher-order polymorphic language | Bernardy, Boespflug, Newton, Peyton Jones, Spiwack | 2018 | `%1 ->`, backward compatible linearity. | https://arxiv.org/abs/1710.09756 |
| Counting Immutable Beans | Ullrich, de Moura | 2019 | Precise RC + destructive update + borrow inference for a pure language (Lean 4). | https://arxiv.org/abs/1908.05647 |
| Quantitative program reasoning with graded modal types | Orchard, Liepelt, Eades | 2019 | Granule's graded modal types. | **[unverified link]** |
| Oxide: The Essence of Rust | Weiss, Gierczak, Patterson, Matsakis, Ahmed | 2019 | Syntactic type-and-borrow calculus with regions. | https://arxiv.org/abs/1903.00982 |
| RustBelt: Securing the foundations of the Rust programming language | Jung, Jourdan, Krebbers, Dreyer | 2018 | Semantic soundness proof in Iris. | https://plv.mpi-sws.org/rustbelt/popl18/ |
| The design and formalization of Mezzo | Balabonski, Pottier, Protzenko | 2016 | Permission-based aliasing control in an ML. | **[unverified link]** |
| Idris 2: Quantitative type theory in practice | Brady | 2021 | QTT in a practical language. | https://arxiv.org/abs/2104.00480 |
| Perceus: Garbage free reference counting with reuse | Reinking, Xie, de Moura, Leijen | 2021 | Precise RC, reuse analysis, FBIP; PLDI distinguished paper. | https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/ |
| Reference counting with frame limited reuse | Lorenzen, Leijen | 2022 | Bounds the stack/heap use of reuse; the runtime story for FBIP. | **[unverified link]** |
| FP²: Fully in-place functional programming | Lorenzen, Leijen, Swierstra | 2023 | FIP calculus: when a pure program provably runs with no allocation; static (uniqueness) vs dynamic (RC) embedding. | https://www.microsoft.com/en-us/research/publication/fp2-fully-in-place-functional-programming/ |
| Linearity and uniqueness: an entente cordiale | Marshall, Vollmer, Orchard | 2022 | A single system with both; separates the concepts. | **[unverified link]** |
| Native implementation of mutable value semantics | Racordon, Shabalin, Abrahams, Zheng, Saeta | 2022 | How MVS compiles to efficient native code. | https://arxiv.org/abs/2106.12678 |
| Mutable value semantics | Google Research / Racordon et al. | 2022 | MVS as third way: ban sharing, not mutation. | https://research.google/pubs/mutable-value-semantics/ |
| Oxidizing OCaml: ownership | Jane Street | 2023+ | Uniqueness mode design, inferred, backwards compatible. | https://blog.janestreet.com/oxidizing-ocaml-ownership/ |
| Mode inference / mode crossing | Lindley et al.; Peters et al. | 2024-26 | Formal inference for OCaml modes. | https://homepages.inf.ed.ac.uk/slindley/papers/mode-inference.pdf ; https://people.mpi-sws.org/~bpeters/papers/mode-crossing.pdf |
| Syntactic and semantic ownership for Rust, Stacked Borrows / Tree Borrows | Jung et al.; Villani et al. | 2020 / 2025 | Aliasing model for unsafe Rust. **[unverified]** | |
| Polonius (rust-lang) | Matsakis, Rakic, Gjengset et al. | 2018- | Location-sensitive borrowck as Datalog; closes NLL case #3. | https://rust-lang.github.io/polonius/ |
| Deny capabilities for safe, fast actors | Clebsch et al. | 2015 | Pony's reference capabilities. | **[unverified link]** |
| Uniqueness and reference immutability for safe parallelism | Gordon et al. | 2012 | Isolation/immutability in C#. | **[unverified link]** |
| Ownership types for flexible alias protection | Clarke, Potter, Noble | 1998 | Ownership types. | **[unverified link]** |
| Checking interference with fractional permissions | Boyland | 2003 | Fractional permissions. | **[unverified link]** |
| Alias types | Smith, Walker, Morrisett | 2000 | Type-level aliasing information. | **[unverified link]** |

## 6. Language constructs that make it ergonomic

- **Parameter modes** — Rust `&`/`&mut`/move; Swift `borrowing`/`consuming`/`inout`; Mojo `read`/`mut`/`owned`; Hylo `let`/`inout`/`sink`/`set`; Cpp2 `in`/`inout`/`out`/`move`; Futhark `*`; Lean `@&`. Observation: three modes cover almost everything (read-only, mutate-and-return, consume), and *mutate-and-return (`inout`) is, in a pure language, sugar for consume-and-return-new*, which is why Hylo can exist with no references.
- **Mutable value semantics (Hylo)** — no first-class references, so there is nothing to alias; `inout` is checked as exclusive access. Sharing is explicit copy. This is the closest published design to the owner's "explicit `List.copy`". Swift reaches it with CoW at runtime instead.
- **Move semantics with inferred last use** — Nim, Cpp2, Rust's moves: a value's last syntactic use is a move automatically, so the user rarely writes `move`. For beni the analogue is that `List.push xs x` consumes `xs` iff `xs` is dead afterwards.
- **Explicit clone/copy** — Rust `.clone()`, Swift `copy`, Hylo `.copy()`, Futhark `copy`. All keep the cost visible.
- **Lifetime annotations vs inference** — Rust infers within a body, requires annotations (or elision rules) at signatures. A language with no references-in-data needs no lifetimes at all (Hylo, Futhark's arrays-as-values).
- **Two-phase borrows and reborrowing** — Rust: `v.push(v.len())` works because the `&mut` is "reserved" first. Directly relevant: `xs.set i (xs.get j)` must not be an error. https://rustc-dev-guide.rust-lang.org/borrow_check/two_phase_borrows.html
- **Copy-on-write as the dynamic backstop** — Swift `isKnownUniquelyReferenced`; Lean/Koka RC = 1 check. Not available to beni's plain JS arrays (no refcount), unless the runtime adds a "shared" flag, which would be a design change **[owner decision]**.
- **Escape hatch for sound-but-incomplete checkers** — Rust `unsafe`, Futhark `copy`, Lean `.clone` equivalents, OCaml `Obj.magic`-style mode overrides. Aligns with CLAUDE.md rule 7.
- **Error message quality** — Rust's borrowck messages (two spans: "value borrowed here" / "later used here", plus "consider cloning") are the benchmark and the main reason people tolerate false positives; Elm-style messages would add the "here is the old version still alive" narrative. Futhark's error index is a good small model: "Using `x`, but this was consumed at `L`." https://futhark.readthedocs.io/en/stable/error-index.html

## 7. Precision and ergonomics evidence

- **Rust false positives.** NLL problem case #3 (conditional return of a borrow from a map lookup, `get_default`), borrowing disjoint fields through methods, borrows kept alive across loop iterations, closures capturing whole structs (fixed partly by edition 2021 disjoint captures). Polonius (location-sensitive) fixes case #3 but has been "almost ready" for years and is costly. Sources: https://rust-lang.github.io/rfcs/2094-nll.html ; https://smallcultfollowing.com/babysteps/blog/2018/04/27/an-alias-based-formulation-of-the-borrow-checker/ **[unverified]**.
- **Rust learning cost** — widely reported "fighting the borrow checker" for 1-3 months; Rust survey and discussion threads; one-line claim here, **[unverified]** for numbers. Rust's checker must also handle `&mut` aliasing and lifetimes in data, which a pure immutable language avoids; the owner's belief that functional languages can be much more precise is plausible for that reason.
- **Inference-only systems fare okay for performance, badly for predictability.** Lean `Array` and Koka/Roc: well-known "your loop is accidentally O(n²) because the array was shared" bug class, discovered by profiling, not by a message. Lean documents it explicitly in *Functional Programming in Lean* (arrays, "Insertion sort and array mutation"). https://lean-lang.org/functional_programming_in_lean/ **[unverified chapter link]**. Koka added `fip` precisely so a developer can *ask* for an error.
- **Annotation burden of error-reporting systems.** Clean and Futhark put `*` in signatures; Futhark requires a function that updates in place to be declared consuming and callers to `copy` or accept loss of the old array. Futhark users hit the alias rules mainly in higher-order code (`map`/`reduce` lambdas capturing arrays, "function body may not consume free variable") — see the error index entries about consuming closures. https://futhark.readthedocs.io/en/stable/error-index.html
- **Uniqueness in higher-order and polymorphic code.** Clean needed uniqueness polymorphism (`.u` attributes) and still rejects some safe programs; Linear Haskell added multiplicity polymorphism to make `map` usable; OCaml's unique/once modes needed "mode crossing" so `int` and other immutable immediates do not poison inference. Expect equivalent machinery for `List.map` taking a function that closes over a list.
- **Silent copy vs error** — the only mainstream *errors-on-uniqueness-violation* languages are signature-annotated (Clean, Futhark, Rust, Mercury, Linear Haskell, Idris 2, Austral). The mainstream *inferred* ones (Swift CoW, Lean, Roc, Koka without `fip`, Nim) copy silently. Nobody ships "inferred, no annotations, error" for general data; Lobster's inference falls back to RC. This is the open research-ish cell the owner's proposal occupies **[unverified claim of absence; worth a deeper search]**.
- **Practitioner reports** (not fetched in this pass; see open questions): Hacker News threads on Perceus/Koka, Lean "compiling with RC", Roc in-place updates, Hylo/Val, Swift ownership manifesto and Rust borrow-checker pain would be the sources. The `hackernews` skill in this repo can fetch them. **[unverified]** — no thread was read.
- **The alternative that avoids the question: local mutation under a pure interface** — Haskell `runST` / Koka `fip`-less loops / Futhark `loop` with `with`: users build a list with a mutable builder inside a scoped computation and freeze. Not an error on sharing; instead a transient-mutation API (Clojure transients, Immer drafts). Zero checker, loses the "every `List.push` is in place" property.

## 8. Implications to carry to the second pass (not recommendations)

- The proposed rule ("editing a list while another part still holds the old version is an error") is, formally, *uniqueness at the update site* inferred by liveness (the old binding is dead after the update, and no alias captured earlier is live). The easy 80% is intraprocedural liveness. The hard 20% is the undo-history example itself: the old version flows into a record/list/model field, and the checker must see the field as an alias. In TEA, the `model` is threaded through `update` and often contains lists in nested records: each `{ model | items = List.push model.items x }` has `model.items` live in the *old* `model` unless `model` is dead too. That is the central test case for any design.
- Lens on the Elm architecture: update functions are `Model, Msg → Model × Cmd`; consuming the old model is natural (the runtime drops it), which suggests a `model` that is *owned* and consumed per update, with `view` borrowing it. Undo history is then precisely the case that has to `copy`.
- Because the output is plain JS arrays with no refcount, the checker has to be sound. Suggest testing soundness the way Futhark and OCaml modes do: a corpus of *must-reject* programs plus differential execution against a copying reference implementation.

## 9. Open questions for a deeper second pass

1. Does any language ship an *inferred* (no signature annotations) uniqueness checker that reports errors? Search Lobster, Ante, Austral's design notes, Verona, Mojo's inference, Jane Street's unique-mode inference results, and the Koka `fip` checker's behaviour on unannotated code.
2. How do OCaml's unique/once modes infer through records, closures and polymorphism, and how often does inference fail in Jane Street's reported experience (blog series plus the ICFP/ML Workshop papers)?
3. Futhark: how many real programs hit alias/consumption errors in higher-order code; what did the 2021-2022 uniqueness rewrite change (read the blog and the type-checker-bug post https://futhark-lang.org/blog/2021-05-11-anatomy-of-a-type-checker-bug.html).
4. Hylo: its `inout`/`sink`/`let`/`set` checker and its handling of closures and projections (subscripts); is there a published false-positive account?
5. Interprocedural summaries: what is the minimal per-function summary (consumes param i, returns alias of param j, captures param k) that keeps the checker modular and deterministic (beni rule 5; incremental builds and the interface firewall must carry it)?
6. Interaction with beni specifics: effects/fibers (a suspended fiber holds a list), `Task.spawn` capture, schemas decoding into lists, `foreign` boundary (JS may keep a reference to an array it was given; `boundary.md`), markup field-identity optimisation (rule 8 relies on identity of untouched values; in-place mutation of an array conflicts with identity-based change detection in the DOM runtime).
7. Quantify: how often does real beni/Elm-style code (the `core/` and `tests/corpus` programs) alias a list across an update? A pass counting dead-vs-live old bindings at `List.push`/`set` sites would price the false-positive rate before committing to errors.
8. Rust-comparison read: Oxide and Polonius papers for what the minimal sound core of a flow-sensitive checker is when there are no lifetimes in data and no interior mutability; whether Polonius-style location-sensitivity is needed at all in a pure language.
9. The non-error alternatives: Perceus-like dynamic uniqueness flag on the JS array (a "shared" bit set on aliasing), Morphic-style whole-program alias specialisation, and transients, with measured costs; and the `fip`-style opt-in error (warn by default, error on request) which fits CLAUDE.md rule 7 best.
10. Read the HN/Zulip discussions: Roc's in-place-update threads (`roc-zulip` skill), Koka/Perceus and Lean RC threads, Swift noncopyable ergonomics feedback, Rust borrowck pain (`hackernews` skill).
