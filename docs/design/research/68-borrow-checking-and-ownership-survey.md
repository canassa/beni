# 68 — Borrow checking and ownership in functional languages: a survey

Status: prior-art survey, 2026-10-09. Nothing here is normative. Written for the owner's
question: could beni make it a compile error to edit a `List` while something else still
holds the old version, so every list can be a plain, in-place-updated JS array and sharing
needs an explicit `List.copy`?

**Second pass, 2026-10-09.** Every entry of the first pass was checked against a primary
source (paper DOI, official documentation, proposal, compiler source, author's site, mailing
list) and its link resolved; the **[unverified]** marks that this resolved are gone, and the
few that remain say why. What changed:

- **The first pass's central claim was wrong.** It said no language infers ownership without
  annotations and reports violations as errors. **Clean does**, and has since the mid-1990s;
  OxCaml does inside a module; Nim does for one narrow rule. §1 and §7.3 carry the evidence.
- **Koka's `fip` was misdescribed.** Its violations are *warnings*, and it checks a function's
  body, never its call sites: whether an update really happens in place is still decided by a
  reference count at run time (§2, §7.2).
- **Lean's `@&` is not part of borrow inference.** It is an FFI-only annotation (§2).
- **Two "OCaml mode inference" links named papers that do not exist under those titles.**
  One PDF is the ICFP 2024 *Oxidizing OCaml* paper; the other is *Mode Crossing*, ICFP 2026
  (§3, §5).
- **Rust's NLL "problem case #3" was misattributed.** The RFC planned to accept it; the
  checker that shipped in 2018 did not; the issue is still open, and Polonius, the fix, reached
  nightly on 2026-08-04 (§7.1).
- **The Morphic citation was wrong** (authors), and no paper on Morphic's alias analysis
  exists; Roc deleted Morphic in 2025–2026. A 2026 paper by the same group on *fully
  automatic* borrow inference was added (§2, §5).
- **Corrected details:** the Cyclone 2002 paper is about regions, not unique pointers; Vale is
  archived; Mojo renamed its conventions; Futhark rewrote its alias checking in 2026 and
  published a warning against the feature; de Vries's thesis is 2009; Swift's `Optional` of a
  noncopyable value is SE-0437, not SE-0427.
- **Added:** practitioner reports (§7.4), the Sisal copy-elimination numbers (§7.2), a
  2023 Lean thesis that tried exactly the owner's error (§7.3), a section on how each system
  keeps messages readable (§10), and design options tied to prior art (§11).

Terms used throughout:

- **Ownership / uniqueness.** A value is *unique* when exactly one live reference to it exists;
  only then can it be changed in place without anyone noticing.
- **Linearity.** A promise about the *future*: this binder will be used exactly once.
  Uniqueness is a guarantee about the *past*: nobody else has a reference
  ([Marshall, Vollmer, Orchard 2022](https://doi.org/10.1007/978-3-030-99336-8_13)).
- **Borrow.** A temporary read-only use that does not take ownership.
- **Inference.** The compiler works the property out; the programmer writes nothing.
- **Mode / convention / annotation.** Something written on a function signature or type,
  such as `*`, `consuming` or `@ unique`, that states ownership.
- **Silent fallback.** When the compiler cannot prove an update safe, it copies (or keeps a
  reference count and copies at run time) and says nothing.
- **False positive.** A program that is actually safe but the checker rejects.

## 1. Summary: what the field says

**Yes, it has been done, once, and the price is known.** The evidence splits into four groups.

1. **Inferred and reported as errors.**
   - **Clean** infers uniqueness for whole function types, top-level functions without
     signatures included, and rejects violations at compile time. The language report:
     "Uniqueness types are deduced automatically"; "attributes not explicitly specified by the
     programmer are added automatically by the type system"
     ([Clean 2.2 report, ch. 9](https://ftp.cs.ru.nl/Clean/html_report/CleanRep.2.2_11.htm)).
     A 2005 mailing-list example is the owner's case exactly: an unannotated local array `a`
     is passed twice to an in-place update and the compiler answers `Uniqueness error …: "a"
     demanded attribute cannot be offered by shared object`
     ([clean-list 2005](https://mailman.science.ru.nl/pipermail/clean-list/2005/002911.html)).
     The *demand* for uniqueness comes from the update primitive's signature (`*{#Int}`);
     user code carries none.
   - **OxCaml** (Jane Street's OCaml) infers `unique`/`once` modes for unannotated code, and a
     violation is a type error — but only within a module. Interfaces (`.mli`) must write
     modes down, and there is no mode polymorphism, so a function's inferred mode is fixed by
     its first use ([Lorenzen et al., ICFP 2024](https://doi.org/10.1145/3674642);
     [pitfalls page](https://oxcaml.org/documentation/uniqueness/pitfalls/)).
   - **Nim** infers moves at the last read of a variable, and a type whose copy operation is
     marked `{.error.}` turns every copy the compiler would need into a compile error:
     "'=copy' is not available for type T; requires a copy because it's not the last read of
     'x'" ([Nim destructors](https://nim-lang.org/docs/destructors.html)). That is the
     owner's rule, for one type, with no annotations anywhere else.
2. **Errors, but modes on signatures.** Rust, Futhark, Swift noncopyable types, Mojo, Hylo,
   Austral, Pony, Linear Haskell, Idris 2, Granule and Mercury. Inside a function body most of
   them infer; at the boundary the programmer writes a marker.
3. **Inferred, silent fallback.** Lean 4, Roc, Koka without `fip`, Swift's copy-on-write,
   Lobster, Nim without `{.error.}`, Sisal and SAC. These check a reference count at run time
   and copy when it is not one; the cost of imprecision is a quiet slowdown, from O(1) to O(n)
   per update.
4. **Opt-in checks.** Koka's `fip` keyword asks for a no-allocation guarantee and emits
   *warnings*; Lean ships `dbgTraceIfShared`, a run-time print when a value is shared.

**Every system that reports errors needs something written down somewhere.** In Clean it is the
primitives' signatures, the data types that hold unique values, and the hard higher-order
cases. In OxCaml it is module interfaces. In Nim it is the type. Nobody has shipped a checker
whose demand is invisible everywhere. For beni, though, Clean's arrangement is close to free:
`List.set` and `List.push` in `core/` would carry the demand, and user code would carry nothing.

**Where precision is lost, and what it costs** (§7.2 has the evidence):

- **Higher-order functions and closures** are the worst place, in every system.
  - Clean's own report calls its higher-order rules "far from trivial … complex and moreover
    incomplete".
  - Futhark has dedicated errors for it ("Function result aliases the free variable x").
  - Koka's `fip` allows only top-level functions as arguments.
  - Swift has no "call once" closure type, so a noncopyable value cannot be consumed from an
    escaping closure.
  - The 2023 Lean uniqueness thesis left higher-order functions out entirely.
- **Polymorphism.** Futhark's 2026 fix makes `id`, pipelines and composition "lossy in terms of
  aliasing". OxCaml has no mode polymorphism, so functions sometimes have to be duplicated.
  Koka rejected static uniqueness typing because it would mean writing functions twice.
- **Containers.** Clean's rule: "If a unique object is stored in a data structure, the data
  structure itself becomes unique as well." The Lean thesis's motivating bug was a list kept
  inside a map, which made every push copy.
- **Branches that keep the old value.**
  - Rust's NLL problem case #3, a borrow returned on one branch only, was promised by the 2018
    RFC and has been a false positive for eight years; its fix reached nightly in August 2026.
  - Koka's checker warns when "not all branches use the same variables".
- **Recursion.** Lean infers its borrow annotations by iterating to a fixpoint over mutually
  recursive groups. The Lean thesis reports weak results for recursive functions over
  recursive types.
- **Module and `foreign` boundaries.** OxCaml stops inference at interfaces. Every system
  with a foreign interface (Lean `@&`, Swift, Mojo) declares ownership there.

**Hard numbers on false-positive rates do not exist** for any of these languages. The nearest
measurement is Sisal's 1990 one, an analysis rather than a type system:

- Across five real programs, its copy-elimination pass removed all 293 static copies.
- It still left 29 of them, about 10%, to a run-time check, because it could not decide them.
- Read as a type system, that is roughly a 10% false-positive rate at update sites, in
  numeric code with no closures.

**The strongest recent warning is Futhark's.** Futhark is the closest production analogue: pure,
arrays updated in place, consumption checked statically. On 2026-09-22 its author published
"Do not let your type system reason about aliasing in your programming language" after an
unsoundness bug: "unless you have a good reason to pick this fight, don't do it. The explosion
in complexity is not trivial"
([post](https://futhark-lang.org/blog/2026-09-22-aliasing.html)). Its other lesson is about
structure. In July 2026 Futhark moved alias checking into a separate pass that runs after type
checking, so that an error can be explained with the full types in hand
([post](https://futhark-lang.org/blog/2026-07-21-rewriting-the-type-checker.html)).

**Soundness is asymmetric for beni.** On a plain JS array with no reference count, a *missed*
alias is a silent wrong answer. So the checker must be sound, and every imprecision surfaces as
a false error that the user answers with `List.copy`. That is Rust's experience, and Rust users
tolerate it mainly because the messages are good (§10).

## 2. Languages that implemented ownership, uniqueness or linearity

### Errors on violation

- **Rust.** Ownership and borrowing: lifetimes are inferred inside a body and declared
  (with elision rules) in signatures; closure capture modes are inferred.
  - [The Book, ch. 4](https://doc.rust-lang.org/book/ch04-00-understanding-ownership.html).
  - [NLL RFC 2094](https://rust-lang.github.io/rfcs/2094-nll.html).
  - Two-phase borrows (`vec.push(vec.len())` works): [rustc-dev-guide](https://rustc-dev-guide.rust-lang.org/borrow-check/two-phase-borrows.html).
  - Polonius, the location-sensitive successor: [2026 project goal](https://goals.rust-lang.org/2026/polonius.html),
    [on nightly since 2026-08-04](https://blog.rust-lang.org/2026/08/04/enabling-polonius-alpha-on-nightly).
- **Clean.** Uniqueness types (`*`) on top of Hindley–Milner inference, used for arrays and
  I/O.
  - Inferred for whole function types; errors at compile time.
  - Uniqueness polymorphism with attribute variables (`u:a`) and inequalities (`[v<=u]`).
  - A partial application holding a unique argument is "essentially unique".
  - [Language report ch. 9](https://ftp.cs.ru.nl/Clean/html_report/CleanRep.2.2_11.htm);
    theory in [Barendsen & Smetsers 1996](https://doi.org/10.1017/S0960129500070109).
- **Futhark.** Uniqueness for arrays only. A parameter marked `*` is consumed. `x with [i] = v`
  updates in place. Using a consumed value is an error, with an error-index page and a `copy`
  fix.
  - Parameters are not inferred; local aliasing is tracked automatically.
  - [Blog 2022](https://futhark-lang.org/blog/2022-06-13-uniqueness-types.html);
    [error index](https://futhark.readthedocs.io/en/stable/error-index.html).
  - The 2026 rewrite: [type checker](https://futhark-lang.org/blog/2026-07-21-rewriting-the-type-checker.html),
    [aliasing](https://futhark-lang.org/blog/2026-09-22-aliasing.html).
  - Paper: [Henriksen et al., PLDI 2017](https://doi.org/10.1145/3062341.3062354).
- **Linear Haskell.** `a %1 -> b` arrows (POPL 2018,
  [arXiv](https://arxiv.org/abs/1710.09756), [DOI](https://doi.org/10.1145/3158093)).
  - GHC's `LinearTypes` is still "experimental, expect bugs, warts, and bad error messages";
    top-level and recursive bindings are inferred unrestricted
    ([GHC guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/linear_types.html)).
  - In-place arrays live in [linear-base](https://hackage.haskell.org/package/linear-base).
- **Idris 2.** Quantities 0/1/ω on binders, written in signatures
  ([Brady, ECOOP 2021](https://arxiv.org/abs/2104.00480), DOI 10.4230/LIPIcs.ECOOP.2021.9).
  How much is inferred inside bodies was not checked.
- **ATS.** Linear and dependent types, heavily annotated. The site now redirects to
  <http://www.cs.bu.edu/~hwxi/atslangweb>.
- **Mercury.** Unique modes `uo` (free→unique), `ui`, `di` (unique→dead), and the
  "mostly unique" `muo`/`mdi`; mode errors are compile errors.
  - The manual: "We have not yet implemented unique modes fully"; only `di`/`uo` work; "The
    Mercury compiler does not (yet) reuse dead values"
    ([manual](https://mercurylang.org/information/doc-latest/mercury_reference_manual/Unique-modes.html)).
  - Mode inference for undeclared predicates, unique modes included, was implemented in 1998
    ([m-dev](https://lists.mercurylang.org/archives/developers/1998-January/002026.html)).
    **[scope unverified: believed local to a module]**
- **Cyclone.** Regions plus unique pointers; no longer supported
  ([site](http://cyclone.thelanguage.org)).
  - The PLDI 2002 paper covers regions ([DOI](https://doi.org/10.1145/512529.512563)).
  - Unique pointers are in Hicks et al., "Experience with safe manual memory management in
    Cyclone", ISMM 2004 **[not fetched]**.
- **Mezzo.** Permissions as types in an ML; a research prototype, inactive
  ([site](https://protz.github.io/mezzo/); [TOPLAS 2016](https://doi.org/10.1145/2837022)).
- **Austral.** Linear types plus Rust-style borrows. It has no type inference at all.
  - Designed so the checker is "simple enough that it can be understood entirely by a single
    person reading the specification".
  - Its linearity checker is "less than 600 lines of code".
  - [Spec](https://austral-lang.org/spec/spec.html);
    [introduction](https://borretti.me/article/introducing-austral).
- **Pony.** Reference capabilities (`iso`, `val`, `ref`, `box`, `trn`, `tag`), with defaults
  declared per type and `recover` to lift a capability
  ([tutorial](https://tutorial.ponylang.io/reference-capabilities/recovering-capabilities);
  [Clebsch et al., AGERE 2015](https://doi.org/10.1145/2824815.2824816)).
- **Swift.** Copy-on-write for ordinary values, plus explicit ownership for noncopyable types.
  - Ownership was designed in the [Ownership Manifesto](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md).
  - Swift 5.9: `borrowing`/`consuming` parameters (SE-0377), noncopyable structs and enums
    (SE-0390), the `consume` operator (SE-0366).
  - Swift 6.0: noncopyable generics (SE-0427), `Optional` of noncopyable values (SE-0437),
    borrowing and consuming pattern matching (SE-0432).
  - Parameter conventions are declared and required for noncopyable types; a `switch` infers
    whether it borrows or consumes.
  - `Array` still cannot hold noncopyable elements.
- **Mojo.** Argument conventions: a default read-only borrow, then `mut`, `var` (formerly
  `owned`), `ref`, `out` and `deinit`.
  - `^` transfers ownership; values are destroyed at their last use; lifetimes ("origins") are
    inferred.
  - [Manual](https://mojolang.org/docs/manual/values/ownership/) (the old docs.modular.com
    URL redirects).
  - Reportedly removed implicit copying from `List` in 2025, so a copy needs `.copy()`
    **[unverified: from a search summary of the changelog]**.
- **Hylo (formerly Val).** Mutable value semantics: no first-class references.
  - Parameter conventions `let`, `inout`, `sink` and `set` are declared, never inferred.
  - Example error: "v was consumed in the previous line / to use v here, pass v.copy()".
  - The compiler is experimental ("expect things to break"), and work has moved to `hylo-new`.
  - [Site](https://www.hylo-lang.org); papers in §5.
- **Koka.** Perceus reference counting with reuse; `fip`/`fbip` function modifiers.
  - `fip` checks the body:
    - owned variables used once;
    - every matched constructor reused;
    - the same variables used on every branch;
    - no allocation, though `fip(n)` allows n;
    - callees must also be `fip`;
    - `^` marks a borrowed parameter.
  - **Violations are warnings, emitted with `emitWarning`**
    ([CheckFBIP.hs](https://github.com/koka-lang/koka/blob/master/src/Core/CheckFBIP.hs)).
  - Call sites are not checked: in-place behaviour is still decided by the reference count at
    run time ([FP² TR](https://www.microsoft.com/en-us/research/uploads/prod/2023/05/fip-tr-v2.pdf)).
  - [Koka book](https://koka-lang.github.io/koka/doc/book.html).
- **OCaml / OxCaml (Jane Street).** Modes `local`, `unique`, `once`, `portable` and
  `contended`.
  - Modes are inferred within a module; interfaces declare them; violations are type errors.
  - As of February 2024, uniqueness was "unused outside of our development tests" because
    in-place reuse was not implemented. The [docs](https://oxcaml.org/documentation/uniqueness/intro/)
    still say overwriting is unimplemented.
  - Blog posts: [locality](https://blog.janestreet.com/oxidizing-ocaml-locality/),
    [ownership](https://blog.janestreet.com/oxidizing-ocaml-ownership/).
- **Granule.** Graded modal types; linear by default, with reuse written as graded boxes in
  signatures. Has uniqueness too: ESOP 2022, OOPSLA 2024 "Functional Ownership through
  Fractional Uniqueness" ([site](https://granule-project.github.io)).
- **Verona.** Regions and concurrent owners. The README says it is "not ready to be used outside
  of research" ([repo](https://github.com/microsoft/verona);
  [OOPSLA 2023](https://doi.org/10.1145/3622846)).
- **Vale.** Generational references with run-time checks; region borrowing is opt-in. Archived,
  succeeded by "Valen" ([site](https://vale.dev)).
- **Inko.** Single ownership with `ref`/`mut` borrows. Moves are checked at compile time, but
  dropping a value that is still borrowed is a *run-time panic*
  ([manual](https://docs.inko-lang.org/manual/latest/getting-started/memory-management/)).
- **Cpp2 / cppfront.** Parameter kinds `in`, `copy`, `inout`, `out`, `move`, `forward`; a
  "definite last use" is moved implicitly
  ([docs](https://hsutter.github.io/cppfront/cpp2/functions/)). Whether a use after a last use
  is an error **[unverified]**.
- **Ante.** Shared and owned types and place-based borrows; "design and implementation are both
  works in progress" ([site](https://antelang.org)). Inference of `uniq` references
  **[unverified: second-hand]**.
- **Carbon.** Its safety strategy says the memory-safety model "will largely match Rust's", but
  no ownership design is specified yet
  ([safety doc](https://github.com/carbon-language/carbon-lang/blob/trunk/docs/design/safety/README.md)).

### Inference with silent fallback

- **Nim (ARC/ORC).** Moves are inferred at the last read. A `sink` parameter whose argument
  is not provably at its last use is copied ("a copy is done instead"). Opt-in error via
  `=copy {.error.}`, above ([destructors](https://nim-lang.org/docs/destructors.html)).
- **Lobster.** Fully automatic ownership: the first holder owns and the rest borrow. It
  removes about 95% of reference-count operations. When it cannot prove single ownership it
  inserts a reference-count increase: "(in Rust, this would cause an error instead)"
  ([memory management](https://aardappel.github.io/lobster/memory_management.html)).
- **Lean 4.** Precise reference counting, with destructive update when the count is 1.
  - Parameters are inferred borrowed or owned ([Counting Immutable Beans](https://arxiv.org/abs/1908.05647) §5.2).
  - `Array.set` copies silently when the array is shared
    ([FPIL, Insertion Sort and Array Mutation](https://lean-lang.org/functional_programming_in_lean/Programming___-Proving___-and-Performance/Insertion-Sort-and-Array-Mutation/)).
  - `@&` is an FFI annotation with "no effect" on functions not marked `@[extern]`
    ([FFI reference](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/)).
- **Roc.** Reference counting, with in-place `List` updates when the count is 1.
  - Morphic, a whole-program alias analysis that proved uniqueness statically, was switched to
    a trivial mode in 2025, then deleted with the old compiler; the Zig rewrite will not port
    it ([Zulip, "remove morphic?"](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/remove.20morphic.3F/near/495632919)).
  - Uniqueness types once existed in the surface language and "were removed because they were
    deemed to be a net negative for the language"
    ([Zulip 2022](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/explicit.20move.20semantics.3F/near/305822253)).
- **SAC (Single Assignment C).** Inferred reference counting and in-place update for arrays.
  It has uniqueness types only for state and I/O
  ([Grelck & Scholz, IJPP 2006](https://doi.org/10.1007/s10766-006-0018-x);
  [Grelck & Trojahner, IFL 2004](https://research.uni-luebeck.de/en/publications/implicit-memory-management-for-sac/)).
- **Sisal.** Compile-time copy elimination, with a run-time "conditional copy" where it cannot
  decide (numbers in §7.2;
  [Cann, Feo, DeBoni 1990](https://www.osti.gov/servlets/purl/6569540)).
- **Haskell (GHC).** No general update analysis. The user-level answers are `ST`/`runST`
  ([Launchbury & Peyton Jones, PLDI 1994](https://doi.org/10.1145/178243.178246)) and
  linear-base.

## 3. Theory and type systems

- **Linear logic.** Girard 1987, TCS 50 ([DOI](https://doi.org/10.1016/0304-3975(87)90045-4)).
- **"Linear types can change the world!"** Wadler 1990: linear types allow in-place update in a
  pure language. There is no DOI ([author page](https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html)).
- **Substructural type systems.** Walker, ch. 1 of *Advanced Topics in Types and Programming
  Languages* ([DOI](https://doi.org/10.7551/mitpress/1104.003.0003)).
- **Uniqueness vs linearity.** Marshall, Vollmer, Orchard, ESOP 2022
  ([DOI](https://doi.org/10.1007/978-3-030-99336-8_13)).
- **Clean's uniqueness typing.** Barendsen & Smetsers, MSCS 6(6), 1996
  ([DOI](https://doi.org/10.1017/S0960129500070109)).
  - Simplified and made Hindley–Milner-inferable by de Vries, Plasmeijer and Abrahamson:
    "Uniqueness Typing Redefined" ([IFL 2006](https://doi.org/10.1007/978-3-540-74130-5_11)),
    "Uniqueness Typing Simplified" ([IFL 2007](https://doi.org/10.1007/978-3-540-85373-2_12)).
  - de Vries's thesis, *Making Uniqueness Typing Less Unique*, Trinity College Dublin, 2009.
  - "Equality-based uniqueness typing", TFP 2007, has no DOI.
- **Regions.** Tofte & Talpin, POPL 1994 ([DOI](https://doi.org/10.1145/174675.177855)) and
  Information and Computation 1997 ([DOI](https://doi.org/10.1006/inco.1996.2613));
  [MLKit](https://elsman.com/mlkit/).
  - Walker & Watkins, "On regions and linear types", ICFP 2001
    ([DOI](https://doi.org/10.1145/507635.507658)).
- **Alias types.** Smith, Walker, Morrisett, ESOP 2000 ([DOI](https://doi.org/10.1007/3-540-46425-5_24)).
- **Fractional permissions.** Boyland, SAS 2003 ([DOI](https://doi.org/10.1007/3-540-44898-5_4)).
- **Separation logic.** O'Hearn, Reynolds, Yang, CSL 2001
  ([DOI](https://doi.org/10.1007/3-540-44802-0_1)); Reynolds, LICS 2002
  ([DOI](https://doi.org/10.1109/LICS.2002.1029817),
  [PDF](https://www.cs.cmu.edu/~jcr/seplogic.pdf)).
- **Ownership types.** Clarke, Potter, Noble, OOPSLA 1998 ([DOI](https://doi.org/10.1145/286936.286947)).
- **Capabilities.** Pony: Clebsch et al., AGERE 2015 ([DOI](https://doi.org/10.1145/2824815.2824816)).
  - Gordon et al., OOPSLA 2012 ([DOI](https://doi.org/10.1145/2384616.2384619)): isolation and
    immutability recovered without annotations at the boundary, in a C# dialect.
- **Quantitative and graded types.**
  - McBride 2016 ([DOI](https://doi.org/10.1007/978-3-319-30936-1_12)).
  - Atkey, LICS 2018 ([DOI](https://doi.org/10.1145/3209108.3209189)).
  - Orchard, Liepelt, Eades, ICFP 2019 ([DOI](https://doi.org/10.1145/3341714)).
- **Usage analysis, inferred.**
  - Wansbrough & Peyton Jones, "Once upon a polymorphic type", POPL 1999
    ([DOI](https://doi.org/10.1145/292540.292545)).
  - Hage, Holdermans, Middelkoop, ICFP 2007 ([DOI](https://doi.org/10.1145/1291151.1291189)).
  - These drive optimisation; whether either reports errors **[unverified]**.
- **In-place update with usage aspects.** Hofmann, ESOP 2000
  ([DOI](https://doi.org/10.1007/3-540-46425-5_11)); Aspinall & Hofmann, ESOP 2002
  ([DOI](https://doi.org/10.1007/3-540-45927-8_4)); Aspinall, Hofmann, Konečný, JFP 2008
  ([DOI](https://doi.org/10.1017/S0956796807006399)).
- **OCaml modes.**
  - *Oxidizing OCaml with Modal Memory Management*, ICFP 2024
    ([DOI](https://doi.org/10.1145/3674642)). Its Appendix B is the mode inference; the PDF
    the first pass called "mode inference" is this paper.
  - *Mode Crossing*, Peters et al., ICFP 2026 ([DOI](https://doi.org/10.1145/3828681)): why
    `int` and other immutable types ignore modes; "deployed in a large industrial codebase".
  - *Data Race Freedom à la Mode*, POPL 2025 ([DOI](https://doi.org/10.1145/3704859)).
  - *Modal Effect Types*, OOPSLA 2025 ([DOI](https://doi.org/10.1145/3720476)).

## 4. Static analyses inferred by the compiler

- **The aggregate update problem.** Hudak & Bloss, POPL 1985
  ([DOI](https://doi.org/10.1145/318593.318660)); Bloss, FPCA 1989
  ([DOI](https://doi.org/10.1145/99370.99373)). The foundational "can this array be updated in
  place?" analyses.
- **Sisal.** Cann's thesis, *Compilation Techniques for High Performance Applicative
  Computation* (Colorado State, 1989); "Retire Fortran?" (Supercomputing '91,
  [DOI](https://doi.org/10.1145/125826.125976); CACM 1992,
  [DOI](https://doi.org/10.1145/135226.135231)).
  - Schnorf, Ganapathi, Hennessy, "Compile-time copy elimination", SP&E 1993
    ([DOI](https://doi.org/10.1002/spe.4380231102)).
- **Escape analysis.** Park & Goldberg, "Escape analysis on lists", PLDI 1992
  ([DOI](https://doi.org/10.1145/143095.143125)); Choi et al., OOPSLA 1999
  ([DOI](https://doi.org/10.1145/320384.320386)).
- **Compile-time garbage collection.**
  - Jones & Le Métayer, FPCA 1989 ([DOI](https://doi.org/10.1145/99370.99375); the ACM
    record misprints "Computer-time").
  - Mohnen, PLILP 1995 ([DOI](https://doi.org/10.1007/BFb0026824)).
  - Mercury: Mazur et al., ICLP 2001 ([DOI](https://doi.org/10.1007/3-540-45635-X_15)). It
    never became a mainline feature.
- **Liveness and last use.** The dataflow behind Rust NLL, Cpp2's definite last use, Nim's move
  inference and Lobster. Exact within a function; across calls it needs a summary of what each
  callee does with its arguments.
- **Perceus reuse** ([PLDI 2021](https://doi.org/10.1145/3453483.3454032)). Pairs a matched
  constructor with an allocation of the same size; a run-time test of the reference count
  decides.
- **Lean borrow inference.** Every parameter starts borrowed. It becomes owned if it is
  reset/reused or passed to an owned position; the second condition "is a heuristic and is not
  required for correctness". Mutually recursive blocks are solved together.
- **Brandon et al., "Fully-Automatic Type Inference for Borrows with Lifetimes"**, OOPSLA 2026
  ([DOI](https://doi.org/10.1145/3798221)). By the Morphic group.
  - Borrows and their lifetimes are inferred in a pure language with no annotations.
  - Programs the inference cannot type get "a handful of reference count operations".
  - Against Perceus: 75–100% fewer increments, 1.48× geometric-mean speedup.
  - The most precise published inference of its kind, and still a silent fallback.
- **Morphic (Roc).** Whole-program alias analysis that specialised functions for in-place
  mutation. No paper. Roc measured 3.13× on a hot `List.set` loop when it worked, but "the core
  algorithm can get way too slow to be worth running during a roc build"
  ([Zulip](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/remove.20morphic.3F/near/495638242)).
- **Rust borrow checking.** Liveness-based region inference (NLL); Polonius adds
  location-sensitivity ([Matsakis 2018](https://smallcultfollowing.com/babysteps/blog/2018/04/27/an-alias-based-formulation-of-the-borrow-checker/)).

## 5. Key papers

| Paper | Authors | Year | Contribution | Link |
|---|---|---|---|---|
| Linear logic | Girard | 1987 | The logic behind all of this. | https://doi.org/10.1016/0304-3975(87)90045-4 |
| Linear types can change the world! | Wadler | 1990 | Linear types give pure in-place update. | https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html |
| The aggregate update problem in functional programming systems | Hudak, Bloss | 1985 | Defines the problem. | https://doi.org/10.1145/318593.318660 |
| Uniqueness typing for functional languages with graph rewriting semantics | Barendsen, Smetsers | 1996 | Clean's uniqueness theory. | https://doi.org/10.1017/S0960129500070109 |
| Uniqueness Typing Simplified | de Vries, Plasmeijer, Abrahamson | 2007 (pub. 2008) | HM-inferable uniqueness. | https://doi.org/10.1007/978-3-540-85373-2_12 |
| Implementation of the typed call-by-value λ-calculus using a stack of regions | Tofte, Talpin | 1994 | Region inference. | https://doi.org/10.1145/174675.177855 |
| Region-based memory management | Tofte, Talpin | 1997 | The full region calculus. | https://doi.org/10.1006/inco.1996.2613 |
| Region-based memory management in Cyclone | Grossman et al. | 2002 | Regions in a C dialect. | https://doi.org/10.1145/512529.512563 |
| Once upon a polymorphic type | Wansbrough, Peyton Jones | 1999 | Use-once inference with polymorphism. | https://doi.org/10.1145/292540.292545 |
| A generic usage analysis with subeffect qualifiers | Hage, Holdermans, Middelkoop | 2007 | Inferred usage analysis. | https://doi.org/10.1145/1291151.1291189 |
| A type system with usage aspects | Aspinall, Hofmann, Konečný | 2008 | In-place update typing. | https://doi.org/10.1017/S0956796807006399 |
| Futhark: purely functional GPU-programming with nested parallelism and in-place array updates | Henriksen, Serup, Elsman, Henglein, Oancea | 2017 | Uniqueness for arrays in production. | https://doi.org/10.1145/3062341.3062354 |
| Linear Haskell | Bernardy, Boespflug, Newton, Peyton Jones, Spiwack | 2018 | `%1 ->` linearity. | https://doi.org/10.1145/3158093 |
| Counting Immutable Beans | Ullrich, de Moura | 2019 | Lean 4 RC, reuse, borrow inference. | https://doi.org/10.1145/3412932.3412935 |
| Quantitative program reasoning with graded modal types | Orchard, Liepelt, Eades | 2019 | Granule. | https://doi.org/10.1145/3341714 |
| Oxide: The Essence of Rust | Weiss, Gierczak, Patterson, Ahmed | 2019 | Borrow-checking calculus. | https://arxiv.org/abs/1903.00982 |
| RustBelt | Jung, Jourdan, Krebbers, Dreyer | 2018 | Semantic soundness of Rust. | https://doi.org/10.1145/3158154 |
| Stacked Borrows; Tree Borrows | Jung et al.; Villani et al. | 2020; 2025 | Aliasing models for unsafe Rust. | https://doi.org/10.1145/3371109 ; https://doi.org/10.1145/3735592 |
| The Design and Formalization of Mezzo | Balabonski, Pottier, Protzenko | 2016 | Permissions in an ML. | https://doi.org/10.1145/2837022 |
| Idris 2: Quantitative Type Theory in Practice | Brady | 2021 | QTT in practice. | https://arxiv.org/abs/2104.00480 |
| Perceus | Reinking, Xie, de Moura, Leijen | 2021 | Precise RC with reuse. | https://doi.org/10.1145/3453483.3454032 |
| Reference counting with frame limited reuse | Lorenzen, Leijen | 2022 | Bounds reuse's space. | https://doi.org/10.1145/3547634 |
| FP²: Fully in-Place Functional Programming | Lorenzen, Leijen, Swierstra | 2023 | The `fip` calculus. | https://doi.org/10.1145/3607840 |
| Linearity and Uniqueness: An Entente Cordiale | Marshall, Vollmer, Orchard | 2022 | Both in one system. | https://doi.org/10.1007/978-3-030-99336-8_13 |
| Native Implementation of Mutable Value Semantics | Racordon, Shabalin, Zheng, Abrahams, Saeta | 2021 | MVS compilation. | https://arxiv.org/abs/2106.12678 |
| Implementation Strategies for Mutable Value Semantics | same | 2022 | MVS, JOT (the Google Research listing is this paper). | https://doi.org/10.5381/jot.2022.21.2.a2 |
| Better Defunctionalization through Lambda Set Specialization | Brandon, Driscoll, Dai, Berkow, Milano | 2023 | Morphic's lambda sets. | https://doi.org/10.1145/3591260 |
| Oxidizing OCaml with Modal Memory Management | Lorenzen, White, Dolan, Eisenberg, Lindley | 2024 | Inferred uniqueness, affinity and locality modes. | https://doi.org/10.1145/3674642 |
| Data Race Freedom à la Mode | Georges et al. | 2025 | Concurrency modes. | https://doi.org/10.1145/3704859 |
| Fully-Automatic Type Inference for Borrows with Lifetimes | Brandon, Driscoll, Dai, Ragan-Kelley, Milano, Aiken | 2026 | Annotation-free borrow inference. | https://doi.org/10.1145/3798221 |
| Mode Crossing | Peters et al. | 2026 | Types that ignore modes. | https://doi.org/10.1145/3828681 |
| Polonius | Matsakis et al. | 2018– | Location-sensitive borrow checking. | https://blog.rust-lang.org/2026/08/04/enabling-polonius-alpha-on-nightly |
| Deny capabilities for safe, fast actors | Clebsch et al. | 2015 | Pony. | https://doi.org/10.1145/2824815.2824816 |
| Uniqueness and reference immutability for safe parallelism | Gordon et al. | 2012 | C# isolation. | https://doi.org/10.1145/2384616.2384619 |
| Ownership types for flexible alias protection | Clarke, Potter, Noble | 1998 | Ownership types. | https://doi.org/10.1145/286936.286947 |
| Checking interference with fractional permissions | Boyland | 2003 | Fractional permissions. | https://doi.org/10.1007/3-540-44898-5_4 |
| Alias types | Smith, Walker, Morrisett | 2000 | Aliasing in types. | https://doi.org/10.1007/3-540-46425-5_24 |
| Static Uniqueness Analysis for the Lean 4 Theorem Prover | Huisinga (master's thesis, KIT) | 2023 | Tried the owner's error for Lean. | https://pp.ipd.kit.edu/uploads/publikationen/huisinga23masterarbeit.pdf |

## 6. Language constructs that make it ergonomic

- **Parameter modes.**
  - Rust: `&` / `&mut` / move. Swift: `borrowing` / `consuming` / `inout`. Mojo: default /
    `mut` / `var`. Hylo: `let` / `inout` / `sink` / `set`. Cpp2: `in` / `inout` / `out` /
    `move`. Futhark: `*`. OxCaml: `@ unique`.
  - Three cover almost everything: read, mutate-and-return, consume.
  - In a pure language mutate-and-return is consume-and-return-new, which is why Hylo works
    with no references.
- **Mutable value semantics (Hylo).** No first-class references, so nothing can alias; sharing
  is an explicit copy. This is the closest published design to the owner's `List.copy`.
- **Move at last use, inferred.** Nim, Cpp2, Mojo's as-soon-as-possible destruction, Lobster.
  The beni analogue: `List.push xs x` consumes `xs` when `xs` is dead afterwards.
- **Explicit copy.** Rust `.clone()`, Swift `copy`, Hylo `.copy()`, Futhark `copy`. Every
  error-reporting system's messages suggest it.
- **Two-phase borrows** let `xs.set i (xs.get j)` style code through: the read happens before
  the write takes ownership.
- **Copy-on-write as a run-time backstop.** Swift's `isKnownUniquelyReferenced`; Lean and Koka
  check for a reference count of 1. Beni's plain JS arrays have no reference count, so this
  would mean adding a "shared" flag at run time **[owner decision]**.
- **Escape hatches.** Rust `unsafe`, Futhark `copy`, Koka's `fip` falling back to RC.
- **Local mutation under a pure interface.**
  - Haskell `runST`; [Clojure transients](https://clojure.org/reference/transients), checked at
    run time; [Immer](https://immerjs.github.io/immer/) drafts in JS.
  - No checker needed, but `List.push` is not in place everywhere.

## 7. Precision and ergonomics evidence

### 7.1 Rust

- **NLL problem case #3.** A function returns a borrow on one branch and mutates on the other
  (`get_default` on a `HashMap`).
  - The [RFC](https://rust-lang.github.io/rfcs/2094-nll.html) planned to accept it by giving
    regions "end points" in the caller.
  - The checker that shipped in 2018 did not. [rust-lang/rust#54663](https://github.com/rust-lang/rust/issues/54663),
    opened 2018-09-29, is still open and labelled `fixed-by-polonius`. Siblings:
    [#51545](https://github.com/rust-lang/rust/issues/51545),
    [#21906](https://github.com/rust-lang/rust/issues/21906) (2015).
- **Polonius.** Polonius Alpha has been on by default on nightly since 2026-08-04, aiming to
  stabilise "prior to the end of the year"
  ([post](https://blog.rust-lang.org/2026/08/04/enabling-polonius-alpha-on-nightly)).
  - The post: "some programs that we *want* to compile don't work with Polonius Alpha (nor NLL
    today)". Its example is a loop that reborrows a linked list.
  - The original Datalog formulation was precise but too slow, hence the cut-down "alpha"
    **[from a search summary]**.
- **Interprocedural false positives.** Niko Matsakis, ["The borrow checker
  within"](https://smallcultfollowing.com/babysteps/blog/2024/06/02/the-borrow-checker-within/)
  (2024): a signature hides which fields a method touches, so disjoint uses still conflict. This
  is the summary problem any modular checker has; the proposed fix is "view types" in
  signatures.
- **Survey data.** Google's ["Rust fact vs. fiction"](https://opensource.googleblog.com/2023/06/rust-fact-vs-fiction-5-insights-from-googles-rust-journey-2022.html)
  (2023):
  - Ownership and borrowing is one of the top three challenging areas.
  - About two thirds of developers were confident within two months.
  - "Only 9% … not satisfied with the quality of diagnostic and debugging information."
- **Practitioners.** ["Leaving Rust gamedev after 3 years"](https://loglog.games/blog/leaving-rust-gamedev/)
  (2024): "The borrow checker *forces* a refactor at the most inconvenient times."
  - In its [HN thread](https://news.ycombinator.com/item?id=40172033), a long-time Rust user
    ([40172746](https://news.ycombinator.com/item?id=40172746)): "even after 10 years … it's not
    clear to me that advanced GUI or gamedev fits well with the borrow checker".
  - This matters for beni because a TEA `update` threading a large model is a UI shape.

### 7.2 Where precision is lost in the systems closest to beni

- **Higher-order code.**
  - Clean's report: "combining uniqueness typing with higher-order types is far from trivial:
    the description given above is complex and moreover incomplete". Users repeatedly misread
    its attribute variables; Edsko de Vries: "A unique function cannot be coerced to a
    non-unique function" ([clean-list 2009](https://mailman.science.ru.nl/pipermail/clean-list/2009/004427.html)).
  - Futhark, 2022: "uniqueness types do not interact well with higher-order functions". Its
    error index has "Function result aliases the free variable x" and a rule against passing a
    consuming function to a higher-order parameter.
  - Koka `fip` allows only top-level functions as arguments.
  - Swift cannot consume a noncopyable value from an escaping closure
    ([forum](https://forums.swift.org/t/80460)); the workaround is an `Optional` taken out of.
- **Polymorphism.**
  - Futhark's 2026 fix makes "id, pipelining, function composition, etc. … lossy in terms of
    aliasing" (a beni program is mostly `▷` pipelines).
  - OxCaml has no mode polymorphism; an unannotated function's modes are fixed by its first
    use, so code is sometimes duplicated.
  - FP² rejects static uniqueness typing because it needs functions written twice, once for
    unique and once for shared arguments.
- **Containers.**
  - Clean propagates uniqueness outward: a record holding a unique list must be unique.
  - The 2023 Lean thesis's real-world bug: an `Array.groupBy` was accidentally quadratic
    because `RBMap.find?` left a second reference to the group inside the map.
  - The beni equivalent is `{ model | items = List.push model.items x }` while the old `model`
    is still reachable.
- **Branches that keep the old value.** Rust case #3 (above). Koka warns when "not all branches
  use the same variables". The 2026 Polonius loop example.
- **Recursion.** Lean solves its borrow annotations by fixpoint over mutually recursive groups,
  which is cheap and deterministic. The Lean thesis reports weak results on recursive functions
  over recursive types.
- **Module boundaries.** OxCaml infers per module; across modules "explicit mode annotations in
  signatures become necessary". Rust and Swift declare at every signature. Roc's whole-program
  Morphic was too slow to run in every build.
- **`foreign` / FFI.** Every system declares ownership at the foreign boundary: Lean `@&` on
  `@[extern]`, Swift and Mojo conventions, Rust signatures. None infers it.
- **How often analyses fail on real code.** Sisal's static copy elimination
  ([Cann, Feo, DeBoni 1990](https://www.osti.gov/servlets/purl/6569540), Table I):

  | Program | Copies before | Unconditional after | Left to a run-time check |
  |---|---:|---:|---:|
  | Livermore Loops | 39 | 0 | 0 |
  | GJ | 5 | 0 | 0 |
  | RICARD | 17 | 0 | 6 |
  | SIMPLE | 214 | 0 | 19 |
  | PSA | 18 | 0 | 4 |

  - About 10% of sites were undecidable statically, in first-order numeric code.
  - Under an error-only rule each of those would be an error or a `copy`.
  - No modern system publishes a comparable false-positive count.

### 7.3 Does anything infer without annotations and report errors?

| System | Inferred without annotations? | Violation is an error? | What must still be written |
|---|---|---|---|
| **Clean** | Yes, whole program, unannotated functions included | Yes | Primitive signatures (`*{#Int}`), data types holding unique values, hard higher-order cases |
| **OxCaml** | Yes, within a module | Yes | Modes in `.mli` interfaces; no mode polymorphism |
| **Nim** | Moves, at last read | Yes, if the type's `=copy` is `{.error.}` | The pragma, once per type |
| Rust | Inside bodies; closure captures | Yes | Function signatures |
| Futhark | Locals | Yes | `*` on consumed parameters |
| Mercury | Mode inference for undeclared predicates (1998) | Yes | Scope **[unverified]** |
| Lobster | Fully | Almost never; inserts an RC increment instead | None |
| Koka `fip` | Analysis inferred | Warnings | The `fip` keyword |
| Lean, Roc, Perceus, SAC, Sisal | Fully | No: silent copy | None |
| Swift, Mojo, Hylo, Austral, Pony, Linear Haskell, Idris 2, Granule | No | Yes | Signatures |

- The first pass's claim of absence is refuted.
- The pattern in every row that reports errors: uniqueness is inferred inside some unit (a body,
  a module, or Clean's whole program), and the *requirement* comes from something annotated.
- For beni that something would be `core/List`'s update functions, which only `core/` writes.
- **Two attempts to add the error to a silent-fallback language both needed annotations in
  types, and neither shipped.**
  - Roc had uniqueness types in the language and removed them as "a net negative".
  - Huisinga's Lean thesis ([PDF](https://pp.ipd.kit.edu/uploads/publikationen/huisinga23masterarbeit.pdf))
    proposed "a type system which … issues an error when referential uniqueness is violated".
    It inferred borrowing (writing it down was "too much of an annotational burden") but kept
    `*` on types. It had no type inference and no higher-order functions, and was never
    integrated.

### 7.4 Practitioner reports on silent fallback

- **Lean** documents the cliff and ships a tool for it.
  - [FPIL](https://lean-lang.org/functional_programming_in_lean/Programming___-Proving___-and-Performance/Insertion-Sort-and-Array-Mutation/):
    "One of the most important steps in optimizing hot loops in Lean code is making sure that
    the data being modified is not referred to from multiple locations."
  - `dbgTraceIfShared` "prints a message … if the value has more than one reference".
  - The [reference manual](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/)
    has no warning of any kind.
  - Huisinga's thesis names the cost: "huge disparities in runtime when referential uniqueness
    is violated by accident … from Θ(1) to Θ(n)".
- **Roc.**
  - Richard Feldman (2026): "needing to be careful about not accidentally storing extra copies
    … ineligible for in-place mutation"; he wants tests "that assert uniqueness of various
    builtin operations"
    ([Zulip](https://roc.zulipchat.com/#narrow/channel/397893-announcements/topic/Iterators/near/600161326)).
  - A 2024 thread on showing clones in the editor concluded "most of these copies are dynamic at
    runtime"; Brendan Hansknecht suggested "a cargo clippy like check" instead
    ([Zulip](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Displaying.20loctations.20of.20memory.20clones.20in.20the.20editor/near/424759468)).
- **Koka, on HN.** aseipp ([36487261](https://news.ycombinator.com/item?id=36487261)) separates
  Perceus ("if an object's refcount is 1, I can do an in place update") from FIP ("you can
  *guarantee* in place updates").
- **Predictability.** tupshin on HN ([13880751](https://news.ycombinator.com/item?id=13880751)):
  "predictable performance is about what the programmer can predict … linear types make it much
  easier to reason about the performance".
- **Futhark** (2022): "Although perhaps clumsy, it has not proven a major problem in practice",
  with the design aim that "programmers can ignore this entire business whenever it is not
  needed". Then the 2026 retreat (§1).
- **No substantive HN thread** was found reporting a real performance cliff from accidental
  sharing in Roc, Koka or Lean; the documentation above is the best evidence.

## 8. Implications for beni (not recommendations)

- **The rule is uniqueness at the update site.** The owner's rule is formally "uniqueness at
  the update site, inferred by liveness": the old binding is dead after the update, and no alias
  taken earlier is still live.
- **The easy part** is liveness within one function, which every system above does exactly.
- **The hard part is the motivating example itself.**
  - The old version flows into a record, a list or the model.
  - In TEA, `update` returns a new model while the runtime holds the old one.
  - `view` reads the model.
  - An undo history keeps old models on purpose.
  - Each is the container and branch case of §7.2.
- **Field identity.** The browser runtime's reference check per hole (rule 8) assumes that an
  untouched value is the same object, and that a changed value is a *different* object. Mutating
  an array in place keeps its identity while changing its contents, so every list read by a
  `view` would either be copied before `view` sees it or defeat change detection.
- **Inference must be sound and deterministic.** A missed alias on a plain array is a wrong
  answer. Every system that infers across functions stores a per-function summary (Lean's
  borrow signature, OxCaml's interface modes). Beni's interface files and incremental firewall
  would have to carry it (rule 5, M4).

## 9. Open questions

1. How many `List` update sites in `core/` and `tests/corpus/` would fail a sound uniqueness
   rule today? This is the only way to price the false-error rate for beni's code, since no
   language publishes one (Sisal's ~10% is the only number).
2. What is the minimal per-function summary that is modular and deterministic: consumes argument
   i, result aliases argument j, captures argument k? How does it travel through a `where`
   clause, a `foreign` declaration, an effect-suspended fiber and `Task.spawn`?
3. Clean's higher-order rules are "incomplete" by its own account. What does Clean actually
   reject in `map`/`fold`-heavy code? Reading the Clean compiler's uniqueness checker would
   answer that.
4. Do Brandon et al.'s 2026 inference results (borrows inferred, a "handful" of fallbacks)
   translate into an error rate if the fallback became an error?
5. Hylo's checker for closures and projections. No false-positive account is published.
6. How field identity in the DOM runtime (rule 8) and in-place mutation interact, measured, not
   argued.

## 10. How each system keeps its errors understandable

- **Rust**, three places named ([Book ch. 8.1](https://doc.rust-lang.org/book/ch08-01-vectors.html)):
  ```
  error[E0502]: cannot borrow `v` as mutable because it is also borrowed as immutable
  4 |     let first = &v[0];
    |                  - immutable borrow occurs here
  6 |     v.push(6);
    |     ^^^^^^^^^ mutable borrow occurs here
  8 |     println!("The first element is: {first}");
    |                                      ----- immutable borrow later used here
  ```
  The Book follows it with a paragraph explaining *why*, and every code has an index page
  ([E0502](https://doc.rust-lang.org/error_codes/E0502.html)). This is the owner's case almost
  verbatim: the old version, the edit, the later use.
- **Futhark.** One page per error with a `copy` fix
  ([error index](https://futhark.readthedocs.io/en/stable/error-index.html)): "Using x, but this
  was consumed at y."
  - Its 2021 bug fix gave intermediate results names so a message could say "Consuming result of
    applying "iota" (at 2:23-28), but this was previously consumed at 4:7-10"
    ([post](https://futhark-lang.org/blog/2021-05-11-anatomy-of-a-type-checker-bug.html)).
  - The 2026 rewrite puts alias checking after type checking so errors have full types.
- **OxCaml.** "This value is used here, but it has already been used as unique at:", and "This
  identifier cannot be used uniquely, because it was defined outside of the for-loop"
  ([source](https://github.com/oxcaml/oxcaml/blob/main/typing/uniqueness_analysis.ml),
  [pitfalls](https://oxcaml.org/documentation/uniqueness/pitfalls/)).
- **Swift.** "'x' used after consume", with notes "consumed here"
  ([DiagnosticsSIL.def](https://github.com/swiftlang/swift/blob/main/include/swift/AST/DiagnosticsSIL.def)).
- **Nim.** "requires a copy because it's not the last read of 'x'".
- **Hylo.** "v was consumed in the previous line / to use v here, pass v.copy() to …".
- **Koka `fip`** (warnings). "the variable x is used multiple times (causing sharing and
  preventing reuse)"; "not all branches use the same variables".
- **Clean, the cautionary example.** `"argument 1 of StereoStream" attribute at indicated
  position could not be coerced *(^ {#*Int},{#*Int})`
  ([clean-list 2003](https://mailman.science.ru.nl/pipermail/clean-list/2003/002479.html)). It
  prints the inferred attribute type with a caret and never names the second use.
- **Austral** keeps errors explainable by keeping the rule tiny: count how many times a variable
  appears.
- **The pattern.** The messages people understand name the place where the old version was
  kept, the place of the in-place edit, and the place where the old version is used later. They
  then offer the fix (`copy`). Inference makes this harder, because the "kept" place may be
  inside another function, and Clean shows what happens when the inferred type is printed
  instead.

## 11. Design options for beni, each with its prior art

These are the shapes the evidence offers, not recommendations.

1. **Clean-style whole-program inference with errors.** The demand sits on `core/List`'s update
   functions; inference carries it through user code; a violation is an error naming three
   places; `List.copy` is the fix.
   - Prior art: Clean, OxCaml within a module.
   - Known costs: higher-order and polymorphic code (Clean: "incomplete"; Futhark: pipelines
     lossy), containers propagating uniqueness, and a summary in every interface file.
2. **Nim-style: moves inferred, error only where a copy would be needed.** It is option 1
   restricted to what liveness can see locally, with an error instead of a silent copy and a
   message saying "not the last read".
   - Prior art: Nim `=copy {.error.}`, Cpp2 definite last use, Mojo.
   - Simpler; more false errors across calls unless callees are summarised.
3. **OxCaml-style: infer inside a module, declare at `pub` boundaries.** Bounded inference and
   clear interface contracts; costs annotations on exported functions.
   - Prior art: OxCaml, Rust, Futhark `*`.
4. **Futhark/Hylo-style declared consumption.** A marker on parameters that consume a list; a
   small, explainable checker.
   - Prior art: Futhark, Hylo, Swift, Austral.
   - Costs annotations everywhere a list is consumed. Futhark's 2026 post is the warning about
     where its complexity ends up.
5. **Silent fallback plus an opt-in guarantee.** In-place when provably unique, otherwise a copy
   (or a run-time "shared" flag on the array), with a `fip`-like marker or a warning that turns
   the copy into a diagnostic where the author asks.
   - Prior art: Koka `fip` (warnings), Lean `dbgTraceIfShared`, Roc's proposed clippy-like
     check, Lobster, Brandon et al. 2026.
   - Fits rule 7's "make it a warning" route. Gives up the owner's "no silent fallback".
6. **Local mutation under a pure interface.** A scoped builder that is mutable inside and frozen
   on exit; no checker.
   - Prior art: `runST`, Clojure transients, Immer.
   - Gives up "every `List.push` is in place".
