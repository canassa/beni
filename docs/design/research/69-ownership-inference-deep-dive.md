# 69 — Ownership inference, a deeper pass: precision, false errors and their wording

Status: prior-art research, 2026-10-09. Nothing here is normative. It is the third pass on the
owner's question in [research 68](68-borrow-checking-and-ownership-survey.md). Could beni make it
a compile error to edit a `List` while another part of the program still holds the old version, so
that every list is a plain JS array updated in place, `List.copy` makes intentional sharing
explicit, and nothing silently falls back to a copy or a persistent structure?

Research 68 established *who* does this. This pass reads the papers, theses, reports and
discussions behind those names, looking for four things:

- how precise an inferred checker can be;
- what a false error costs the person who gets it;
- how the checker stays free of annotations;
- how its errors should be worded.

Terms, defined once:

- **Unique.** Exactly one live reference to a value exists, so changing it in place is invisible.
- **Inferred.** The compiler works the fact out and the programmer writes nothing.
- **Demand.** The place that *requires* uniqueness. For beni this is `List.set`, `List.push` and
  the other update primitives in `core/`.
- **False error.** The checker rejects a program that would in fact have been safe.
- **Silent fallback.** Where the compiler cannot prove an update safe, it copies (or checks a
  reference count at run time) and says nothing.
- **Sound.** The checker never accepts a program that would let someone see an in-place change.
  On a plain JS array a missed alias is a wrong answer, so beni's checker must be sound and every
  imprecision becomes a false error.
- **Unification-based versus directional analysis.** A unification-based analysis puts every
  value that ever meets another into one bucket, the way Hindley–Milner type inference merges
  type variables. A directional (subset-based) analysis records which way each value flows. §2.5
  shows why the difference decides precision.

Every link was fetched or its DOI resolved during this pass, unless it is marked
**[unverified]** with the reason. "Abstract only" means the full text was not read.

---

## 1. Summary in plain language

### 1.1 What this pass adds to research 68

**1. Clean's recipe for staying annotation-free is published, and it works on ordinary code.**
Barendsen and Smetsers (1995, 1996) and de Vries (2007) give it in three parts:

- the demand lives only on the update primitives' types;
- every constructor's result may be either unique or shared;
- a program that type-checks without uniqueness still type-checks with it.

Their stated goal: "A programmer writing traditional functional programs should not have to worry
about uniqueness" (§2.1). For beni this is the whole design in one sentence: `core/List`
carries the demand, and user code carries nothing.

**2. The precision of those checkers comes from a small set of known rules, and beni gets the
most important one cheaply.**

- **Reads before writes.** Every system that accepted realistic array code has a rule that a
  read of the old version, ordered before the write, does not count as sharing:
  - Clean's "observing" references;
  - Sisal's artificial dependency edges, 347 of them in one program;
  - Sastry, Clinger and Ariola's order-of-evaluation analysis;
  - Aspinall and Hofmann's read-only "usage aspects";
  - Odersky's observers.

  Without it, `List.set xs i (List.get xs j + 1)` is rejected. Beni is strict, so a read that
  appears before the write in the source does run first. Clean, being lazy, had to fight its own
  unevaluated thunks for this.
- **Directional flow, not unification.** Emre et al. (OOPSLA 2023) measured what happens when
  an alias analysis is unification-based. In tmux, "having only 4 pointers marked unsafe is
  enough to force 85% of the 4,635 pointers in the program to be marked unsafe". A
  subset-based or context-sensitive analysis improved the result "by an order of magnitude".
  If beni piggy-backs uniqueness on its Hindley–Milner unifier, one shared list could make
  every list it ever met "shared".
- **The best answer, not merely an answer.** Clarke et al.'s survey explains why ownership
  inference disappoints: it finds "any solution that satisfies the constraints, but cannot give a
  best solution". Aspinall, Hofmann and Konečný prove that for first-order code a best (most
  unique) typing exists and is found by an optimistic fixpoint. Lean's borrow inference has the
  same shape: start everything borrowed, and weaken only what must be weakened.

**3. The one hard number, Sisal's, is better than research 68 said.** Reading the 1990 report's
text next to its Table I:

- all 29 run-time copy checks are attributed to rows of a 2-D array being shared;
- 25 of them (RICARD 6, SIMPLE 19) are *real* sharing, which the owner's rule would rightly
  report, and "they executed only once each";
- only PSA's 4 come from "the possibility of row sharing", meaning the analysis could not
  decide.

That is **4 analysis failures in 293 copy sites, about 1.4%**, not ~10%. The code is
first-order numeric code with no closures, which is the easy case.

**4. The hard places are unchanged and still unmeasured.** No source measures a false-error
rate for an inferred uniqueness checker in a functional language. Both searches confirmed this
gap is real, not a search miss. Every deeper source names the same places where precision is
lost:

- **Closures called more than once.** De Vries (2009): a closure that only *reads* an array but
  is called in a loop forces that array to be non-unique "even though you only read from it".
- **Polymorphic plumbing.** Futhark 2026: "id, pipelining, function composition" become
  "lossy in terms of aliasing", producing "spurious and annoying aliasing errors; the kind where
  you end up frustrated with the idiotic type checker that rejects obviously sensible programs".
- **Containers.** A list inside a record or a map. This is Lean's accidentally quadratic
  `groupBy`.
- **Module boundaries.**
  - OxCaml found 27,382 locality annotations in 2,648 interface files, and 85 functions
    duplicated because modes have no polymorphism.
  - A Mode Crossing count shows annotations added "only when needed to fix concrete type
    errors": about 6,000 in 80 million lines.

**5. False errors have a measured price in Rust, and the price is confusion more than effort.**

- Only 39.6% of experienced Rust users say they "always" understand ownership errors
  (Zhu et al. 2022).
- Learners fixed a rejected program in 46% of cases. They almost never recognised a
  rejected-but-safe program as safe: 3 of 15 on one task (Crichton et al. 2023).
- A randomised trial with 428 students found an aliasing task took "4 hours vs. 12 hours"
  with a garbage collector instead of the borrow checker (Coblenz et al. 2022).
- Crichton (2020) names the root cause. A sound but incomplete checker produces errors that
  "may arise from either ownership-unsound behavior or limitations of the analyzer", and users
  cannot tell which.

**6. Designers who tried "inferred, with errors" mostly retreated.**

- Roc removed uniqueness types as "a net negative".
- Idris 1's uniqueness types were "experimental" and gone in Idris 2.
- Swift made "no implicit copies" opt-in, per binding and not transitive. Its 2025 "explicit
  copies mode" thread insists the rule be a fixed, specified set "even in debug builds", never
  "what -O is able to eliminate" (McCall).
- Futhark kept its rule but published a warning against the feature.
- Graydon Hoare, on Rust's lifetimes: "They were supposed to all be inferred, and they're not".

Clean is the exception. It has shipped exactly this since the 1990s and its users built real
programs with it, though its own report calls the higher-order part "complex and moreover
incomplete".

**7. In JavaScript nobody checks sharing statically, and the failures people hit are silent.**

- **Every library checks at run time, or not at all.** Immer, Immutable.js, Clojure(Script)
  transients, Mutative and Gren's `Array.Builder` all work this way. The guards are ownership
  tokens, a sticky "already used" bit, or `Object.freeze`.
- **Redux names the bug.** "Mutating state is the most common cause of bugs in Redux
  applications" ([Redux style guide](https://redux.js.org/style-guide/)).
- **React drops the update silently.** When state is mutated in place, React "will ignore your
  update" because `Object.is` sees the same object.
- **Koka switched its in-place reuse off for its JS backend.** The JS vector write begins
  `let a = Array.from(ref.value)  // make copy :-(`.

A compile-time rule would be new on this platform. It would also replace a whole class of silent
bugs and the run-time machinery that guards against them. That machinery costs 2–3× a
hand-written reducer for Immer by its own figures, and 15–90× for proxy drafts and freezing on
some workloads (Mutative's table).

### 1.2 More or less plausible?

**More plausible than research 68 suggested for the narrow form, and no more plausible for the
broad form.**

- **The narrow form is well supported.** The demand sits only in `core/List`; inference stays
  inside a module or a function plus stored summaries; reads ordered before writes; directional
  flow. Clean shipped it, Futhark's 2022 report says most uses "tends to be quite straightforward
  and localised", and Sisal's honest rate of analysis failures in first-order code is about 1%.
- **The broad form is where every system struggled.** Here the list lives inside the TEA model
  that the DOM runtime keeps for its identity checks, flows through `▷` pipelines and closures
  passed to `List.map`, and crosses modules. Nobody has published how often a sound checker
  would reject such code, because nobody who tried it measured.

Research 42 §0 points the same way from beni's own measurements:

- The TEA model is shared by construction, because the runtime keeps the array it rendered.
- Its static variant R0 reached every win the run-time variants did. Its "copy first" fallback
  at an unprovable call was "harmless at a message boundary and catastrophic in a loop".

The owner's rule turns that fallback into an error. The errors would then cluster exactly at
message boundaries, the TEA `update`, which is where a beginner meets the language first.
Crichton's 2024 data shows that is where learners give up: "Chapter 4 [Ownership] is a
significant drop-off point".

### 1.3 What would make it precise

Each item comes from a source below:

1. **Demand only in `core/`.** Constructors are polymorphic in uniqueness, and a program that
   type-checks without the rule type-checks with it, except for the update calls (Clean,
   de Vries §6).
2. **Reads before writes.** Order the arguments' evaluation so a read of the old version is not
   sharing. Beni is strict, so the source order is already the evaluation order (Sisal,
   Sastry et al., Clean's observing references).
3. **Directional, context-sensitive flow** of "who may still hold this list", never
   unification-based (Emre et al.).
4. **A best solution** found by an optimistic fixpoint, starting from "everything unique", so the
   answer never depends on the solver's luck (Aspinall–Hofmann–Konečný, Lean).
5. **Per-function summaries in the interface.** For example: consumes argument *i*, result
   aliases argument *j*. Both OxCaml and Lean freeze the boundary. Klabnik's warning: "If it did,
   changing the body of the function would change its signature", so an edited body can raise
   errors in other modules, and the incremental firewall must hash the summary.
6. **A specified, fixed rule, separate from the optimiser.** It must never be "what the inliner
   happened to remove" (McCall). Koka's own paper found reuse analysis "fragile with respect to
   small program transformations".
7. **Element types that cannot be written ignore uniqueness.** This is OxCaml's mode crossing:
   an `Int` or an immutable record inside a list never raises a uniqueness question.
8. **A separate pass after type checking,** so every message can name full types and real
   places (Futhark 2026).
9. **Closures that only read a captured list treated as read-only.** This is Aspinall–Hofmann's
   aspect 3. No source shows it working for higher-order code. It is the open research
   question that matters most for `List.map (λx → … xs …)`.

---

## 2. The material, by topic

Each entry gives a link, year and authors, then what it contributes.

### 2.1 Clean and uniqueness typing

- **Clean 2.2 Language Report, ch. 9 and §4.4.1.** Plasmeijer, van Eekelen et al., Radboud.
  [ch. 9](https://ftp.cs.ru.nl/Clean/html_report/CleanRep.2.2_11.htm),
  [arrays](https://ftp.cs.ru.nl/Clean/html_report/CleanRep.2.2_6.htm).
  - **Containers.** "If a unique object is stored in a data structure, the data structure
    itself becomes unique as well."
  - **Higher-order code.** A partial application to a unique argument is "*essentially* unique".
  - **Evaluation order.** References "guarded by an expression or … preceded by a strict let"
    are *observing*, not sharing, and branches of one match are *alternatives*.
  - **Read-then-update has its own syntax.** `!` selection returns the element and the array
    together, which is "very handy for destructively updating … arrays with values that depend
    on the current contents".
  - **For beni.** It shows that the rules Clean needed beyond plain inference are about
    evaluation order and containers, and that read-then-update needed an API shape of its own.
- **Barendsen & Smetsers, "Conventional and uniqueness typing in graph rewrite systems",
  FSTTCS 1993.** [DOI](https://doi.org/10.1007/3-540-57529-4_42).
  - The foundational system.
  - Currying needs "a restriction on the subtyping relation w.r.t. → types". The higher-order
    difficulty was there from the first paper.
- **Barendsen & Smetsers, "Uniqueness Type Inference", PLILP 1995.**
  [DOI](https://doi.org/10.1007/BFb0026821). The preprint, "Uniqueness Typing in Theory and
  Practice", was read in full
  ([ps.gz](https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1995/bare95-unitypeinference.ps.gz)).
  - **Design goal (§1).** Programs that type-check under Hindley–Milner "remain so, by
    considering all types as non-unique".
  - **The canonical false error (§6).** Guzmán and Hudak's graph-marking `mark` does
    `lookup g loc` and then `update g …`, and "will be rejected by the type system … g is used
    twice". The fix was an API change: a `lookup` that returns the array too.
  - **Higher-order code.** `foldr` gets a non-unique function argument.
- **Barendsen & Smetsers, "Uniqueness typing for functional languages with graph rewriting
  semantics", MSCS 6(6), 1996.** [DOI](https://doi.org/10.1017/S0960129500070109).
  - **Transparency (§8).** "If one disregards the uniqueness information the types are as one
    would expect."
  - **Inference does not search.** "If this attempt fails … we do not try any specific
    instances but consider the expression untypable." Recursive uses are not instantiated, as
    in Hindley–Milner.
  - **For beni.** Simple, predictable inference, at the price of some rejections in recursion.
- **Smetsers, Barendsen, van Eekelen, Plasmeijer, "Guaranteeing safe destructive updates
  through a type system with uniqueness information for graphs", 1994.**
  [DOI](https://doi.org/10.1007/3-540-57787-4_23),
  [PDF](https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1994/smes94-guaranteeing.pdf).
  - **§4.** A function's arguments are split into "preliminaries", evaluated first, and
    "alternate" groups. This is the reads-before-writes rule written into the type system.
  - **§9.** Real programs were built with it, "ranging from a window-based text editor to a
    relational database". That is an anecdote, not a count.
- **de Vries, Plasmeijer, Abrahamson, "Uniqueness Typing Redefined", IFL 2006.**
  [DOI](https://doi.org/10.1007/978-3-540-74130-5_11).
  - **Error quality.** The inference algorithm "is based on algorithm W and inherits its
    associated problems, in particular unhelpful error messages". The authors point to Heeren's
    constraint-based approach from Helium instead.
  - **For beni.** Its checker is constraint-based already (`checker-v2.md`), which is the
    recommended shape.
- **de Vries et al., "Equality Based Uniqueness Typing", TFP 2007 draft.**
  [PDF](https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/2007/vrie2007-TFP07-EqualityBasedUniquenessTyping.pdf).
  - **What not to print.** A simplified system may report "The function you are applying is
    too unique (please use it more than once)".
- **de Vries, Plasmeijer, Abrahamson, "Uniqueness Typing Simplified", IFL 2007 (LNCS 2008).**
  [DOI](https://doi.org/10.1007/978-3-540-85373-2_12).
  - **Partial application** "is probably the most subtle aspect of uniqueness typing" (§4.2).
  - **Annotation-free through library types (§6).** Subtyping becomes unnecessary "if we are
    careful when assigning types to library functions". For example, `newArray` returns an
    array that may be unique or shared.
  - **The price.** `if isEmpty arr then shrink arr else grow arr` "would be rejected" without a
    rank-2 annotation, which the authors call "rare enough". That is not measured.
  - **Recursion.** Every binding in a recursive group is forced non-unique.
- **de Vries, *Making Uniqueness Typing Less Unique*, PhD thesis, Trinity College Dublin,
  2008/2009.** [TARA record](https://www.tara.tcd.ie/items/718ad14a-d935-4d9e-8233-8305db9cda1c/full)
  **[unverified: the repository answers 403 and the file is a 167 MB scan]**. Its content is the
  three papers above.
- **Clean mailing list, rejections in the wild.**
  - [2009, de Vries](https://mailman.science.ru.nl/pipermail/clean-list/2009/004427.html).
    `addInPlace arr1 arr2` passes a closure reading `arr2` to a loop, so "arr2 must be
    non-unique … even though you only read from it". This is the closure false error in its
    purest form.
  - [2011, Achten](https://mailman.science.ru.nl/pipermail/clean-list/2011/004781.html).
    `demanded attribute cannot be offered by shared object`, caused by reading a field and
    passing the record on. The fix was to pattern-match the field first. In lazy Clean the
    field read is a thunk that outlives the update; a strict language does not have this
    problem.
  - [2002, Todescato](https://mailman.science.ru.nl/pipermail/clean-list/2002/002153.html).
    An overloaded monadic bind cannot carry the uniqueness constraint, because it is "hidden in
    the unary type constructor". For beni, `where` clauses and generic code could hit this.

### 2.2 Classic update-in-place and sharing analyses

- **Hudak & Bloss, "The aggregate update problem in functional programming systems", POPL
  1985.** [DOI](https://doi.org/10.1145/318593.318660) (DOI only).
  - It defines the problem.
- **Hudak, "A semantic model of reference counting and its abstraction", LFP 1986.**
  [DOI](https://doi.org/10.1145/319838.319876) (DOI only).
  - Abstract reference counting.
  - Later papers describe it as exponential in time and tied to one fixed evaluation order
    (Sastry et al.; Wand & Clinger). It is the precise-but-too-slow end of the spectrum.
- **Bloss, "Update analysis and the efficient implementation of functional aggregates", FPCA
  1989.** [DOI](https://doi.org/10.1145/99370.99373) (DOI only).
  - Her Yale thesis was not found online.
- **Gopinath & Hennessy, "Copy elimination in functional languages", POPL 1989.**
  [DOI](https://doi.org/10.1145/75277.75304) (DOI only). The analysis behind Sisal's optimiser.
- **Cann, Feo, DeBoni, "SISAL 1.2: High-Performance Applicative Computing", LLNL 1990.**
  [OSTI](https://www.osti.gov/servlets/purl/6569540). Read in full again for this pass; the
  numbers are in §3.
  - **Run-time checks.** Each one is "conditional copy … Since we usually avoid the copy, the
    runtime test is cost effective".
  - **Ordering edges.** IF2UP adds "artificial dependence" edges so that reads run before writes:
    114 in Loops and 347 in SIMPLE.
  - **Correction to research 68.** The text attributes every conditional copy to row sharing.
    RICARD's and SIMPLE's are real sharing, which "executed only once each"; PSA's 4 are "the
    possibility of row sharing". So the analysis failed to decide in 4 of 293 copy sites.
- **Sastry, Clinger, Ariola, "Order-of-evaluation analysis for destructive updates in strict
  functional languages with flat aggregates", FPCA 1993.**
  [DOI](https://doi.org/10.1145/165180.165222) (abstract only).
  - It picks the evaluation order that makes updates destructive.
  - It is "more precise than Hudak's abstract reference counting" and runs "in close to linear
    time for typical programs".
  - First-order code with flat arrays only.
  - **For beni.** Reordering is a precision tool, but beni cannot reorder effectful code, so it
    can only use the order the source already gives.
- **Wand & Clinger, "Set constraints for destructive array update optimization", JFP 11(3),
  2001.** [DOI](https://doi.org/10.1017/S0956796801003938).
  - Earlier analyses "required exponential or doubly exponential time … and were less
    effective".
  - Limits: "works only for arrays containing scalar data"; removing "the restriction to
    first-order programs" is left open.
  - **For beni.** Nested lists and higher-order code were still open in 2001.
- **Draghicescu & Purushothaman, "A uniform treatment of order of evaluation and aggregate
  update", TCS 1993.** [DOI](https://doi.org/10.1016/0304-3975(93)90110-f) (DOI only).
  - First-order, lazy, exponential.
- **Hartel & Vree, "Experiments with destructive updates in a lazy functional language",
  Computer Languages 20(3), 1994.** [DOI](https://doi.org/10.1016/0096-0551(94)90003-5)
  (abstract only).
  - On real applications they were not convinced the updates "could have been achieved without
    application specific knowledge".
  - No analysis was "applicable to non-flat domains in polymorphic languages with higher order
    functions".
- **Odersky, "How to make destructive updates less destructive", POPL 1991.**
  [DOI](https://doi.org/10.1145/99583.99590) (abstract only).
  - "A static criterion … which checks that any side-effect which a function may exert via a
    destructive update remains invisible". That is exactly the owner's rule, stated as a check
    rather than an optimisation.
  - Follow-up, "Observers for linear types", ESOP 1992
    ([DOI](https://doi.org/10.1007/3-540-55253-7_23)): short-lived read-only observers.
- **Guzmán & Hudak, "Single-threaded polymorphic lambda calculus", LICS 1990.**
  [DOI](https://doi.org/10.1109/LICS.1990.113759) (abstract only).
  - Single-threadedness is inferred.
  - `let*` puts reads before writes.
  - Goal: mutations "natural", behaviour "easy to reason about".
- **Wadler, "Is there a use for linear logic?", PEPM 1991.**
  [PS](https://homepages.inf.ed.ac.uk/wadler/papers/linearuse/linearuse.ps).
  - Pure linearity forces `lookup` to return the array, "a very strict form of single
    threading".
  - "In practice one would prefer a system where only update operations are sequentialised but
    lookups can occur in parallel."
  - This is the argument for read-only uses in any beni rule.
- **Hofmann, "A type system for bounded space and functional in-place update", ESOP 2000.**
  [DOI](https://doi.org/10.1007/3-540-46425-5_11) (content not read).
  - LFPL: the programmer passes explicit "diamond" space tokens.
  - This is the fully explicit end of the spectrum, the opposite of what the owner wants.
- **Aspinall & Hofmann, "Another type system for in-place update", ESOP 2002.**
  [DOI](https://doi.org/10.1007/3-540-45927-8_4),
  [PDF](https://homepages.inf.ed.ac.uk/da/papers/readonly/readonly.pdf).
  - Linear schemes are "restrictive in practice, and more restrictive than necessary".
  - Three *usage aspects* for each argument:
    1. destroyed;
    2. read and shared with the result;
    3. read and not shared.
- **Aspinall, Hofmann, Konečný, "A type system with usage aspects", JFP 18(2), 2008.**
  [DOI](https://doi.org/10.1017/S0956796807006399),
  [PDF](https://homepages.inf.ed.ac.uk/da/papers/readonly-long/usageaspects.pdf).
  - **§6.2.** For every typable first-order program there is "a typing with best (i.e. largest)
    usage aspects", found "using an iterative search for a fixed point, starting with the most
    optimistic typing" ([Konečný 2003](https://doi.org/10.1007/3-540-44904-3_14)).
  - **For beni.** The precise answer exists and is computable for first-order code. Higher-order
    code is future work.
- **Shankar, "Static analysis for safe destructive updates in a functional language", LOPSTR
  2001.** [DOI](https://doi.org/10.1007/3-540-45607-4_1) **[abstract only; PDF not reached]**.
  - Higher-order and eager, with a correctness proof, in PVS's code generator.
  - Silent fallback; no figures found.
- **Hage & Holdermans, "Heap recycling for lazy languages", PEPM 2008.**
  [DOI](https://doi.org/10.1145/1328408.1328436) (abstract only).
  - A light user annotation, checked by "type-based uniqueness and constructor analysis".
  - Dan Piponi's [reaction](https://mail.haskell.org/pipermail/haskell-cafe/2008-May/042784.html):
    it "keeps that annotation secret from the programmer … this idea makes it impossible for a
    developer to reason about whether their code will compile".
  - That is the core risk of an annotation-free checker that reports errors, stated in 2008.
- **Yung, *Destructive Effect Analysis and Finite Differencing for Strict Functional
  Languages*, PhD thesis, NYU, 1999.** [PDF](https://cs.nyu.edu/media/publications/yung_chung.pdf).
  - Figure 3.10: optimised run time was 0.159–0.636 of always copying.
  - This prices copying, not precision.
- **SAC: Grelck & Scholz, IJPP 2006.** [DOI](https://doi.org/10.1007/s10766-006-0018-x)
  (DOI only).
  - Reference counting with silent fallback.
  - No in-place fraction found.

### 2.3 Languages that check consumption statically today

- **Futhark.** All by Troels Henriksen (and co-authors).
  - **"Do not let your type system reason about aliasing in your programming language" (2026).**
    [Post](https://futhark-lang.org/blog/2026-09-22-aliasing.html).
    - **Conservative on purpose.** After `if … then A else B` the result aliases both,
      "because while rejecting a program at compile-time can be annoying, allowing a program to
      use a consumed value would be disastrous".
    - **A soundness fix broke ordinary code.** Patterns that are "very common in module-generic
      Futhark code" became type errors.
    - **The stated goal is now out of reach.** Programmers should "pretend that this feature
      does not exist at all, whenever they do not need it. This is not easy at all."
    - **Annotations crept in.** Freshness now has to be written as `*` on most prelude return
      types.
    - **Proposed remedy.** Use parametricity, the "free theorem", to infer that `id`'s result
      aliases exactly its argument, without growing the type language.
    - **For beni.** This is the most direct evidence that polymorphic pipelines are the weak
      point, and it names a principled fix.
  - **"Uniqueness Types and In-Place Updates" (2022).**
    [Post](https://futhark-lang.org/blog/2022-06-13-uniqueness-types.html).
    - **Always fixable.** "An alias-related type error can always be fixed by copying."
    - **Kept within one function.** Composition should not depend on "some complicated
      black-box alias analysis".
    - **Simple ordering rules.** Order is syntactic: `let B = A with [i] = v; let x = A[i]` is
      rejected and works if the two lines are swapped. "More important to have simple than
      flexible rules."
    - **Closures.** A closure may not consume a free variable, because `map` might call it
      twice.
    - **Usage.** "Most uses of uniqueness in real Futhark programs tends to be quite
      straightforward and localised." This is qualitative only.
  - **"Anatomy of a type checker bug" (2021).**
    [Post](https://futhark-lang.org/blog/2021-05-11-anatomy-of-a-type-checker-bug.html).
    - **Freshness is inferred** for unannotated functions.
    - **The bug.** Alias tracking keyed on names missed unnamed intermediate results. The fix
      gives every application a name, which also made the messages better (§2.9).
    - **Long chains are hard to explain.** "It can also sometimes be difficult to explain to the
      user why something is not allowed."
  - **"Rewriting the type checker" (2026).**
    [Post](https://futhark-lang.org/blog/2026-07-21-rewriting-the-type-checker.html).
    - Alias checking became its own pass over "a fully well-typed program".
    - The old design was "hindered by having to work with incomplete type information".
  - **Henriksen, PhD thesis, DIKU 2017.**
    [PDF](https://futhark-lang.org/publications/troels-henriksen-phd-thesis.pdf).
    - **§2.5.1.** The check is a "relatively simple conservative and intra-procedural aliasing
      analysis … signal an error otherwise".
    - **§5.4.** It is tractable *because* Futhark avoids "pointer structures". Beni's lists sit
      inside records and union types, so beni does not have that luxury.
    - **§10.1.5.** In-place updates are worth 8.3× on k-means and 1.7× on tridag, and one
      benchmark "is not expressible without" them.
  - **Henriksen, Serup, Elsman, Henglein, Oancea, PLDI 2017.**
    [DOI](https://doi.org/10.1145/3062341.3062354), [PDF](https://futhark-lang.org/publications/pldi17.pdf).
    - Attributes only on function parameters and results.
    - No error-frequency data.
  - **[Error index §8.1](https://futhark.readthedocs.io/en/latest/error-index.html).**
    - 11 of 13 consumption-section entries are about aliasing, and each has a minimal example.
    - Every fix ends with "We can always break aliasing by using a copy expression".
- **OxCaml (Jane Street).**
  - **Lorenzen, White, Dolan, Eisenberg, Lindley, "Oxidizing OCaml with Modal Memory
    Management", ICFP 2024.** [DOI](https://doi.org/10.1145/3674642),
    [PDF](https://homepages.inf.ed.ac.uk/slindley/papers/mode-inference.pdf).
    - **Inference.** Modes "can be completely inferred". A simple solver handles the inequality
      constraints.
    - **No mode polymorphism (§6.6).** "As of April 2024, we count 85 functions duplicated
      across different locality modes in our corporate codebase."
    - **Annotation counts (§7).** "187,765 .mli files. Of these, 2,648 have a use of local or
      global, with a total of 27,382 occurrences". Implementations "can generally infer"; only
      interfaces must write modes down. These are locality figures, not uniqueness.
    - **Uniqueness has no deployment yet.** Uniqueness was "unused outside of our development
      tests".
    - **Higher-order code.** Functions that pass borrowed values to callbacks have "rank-1 types
      that can be fully inferred", where Rust needs higher-rank types.
  - **Peters, Jacobs, Kalinichenko, Stevenson, Smith, Dreyer, Eisenberg, "Mode Crossing", ICFP
    2026.** [DOI](https://doi.org/10.1145/3828681),
    [PDF](https://iris-project.org/pdfs/2026-icfp-modecrossing.pdf).
    - **Annotation count (§5).** In 80 million lines, "roughly 6,000 modal kind annotations"
      were added "only when needed to fix concrete type errors".
    - **Without the feature,** adoption "would have been infeasible".
    - **For beni.** Making immutable element types exempt from uniqueness is not a nicety; it is
      what makes the rule bearable.
  - **[Pitfalls](https://oxcaml.org/documentation/uniqueness/pitfalls/) and
    [introduction](https://oxcaml.org/documentation/uniqueness/intro/) pages.**
    - Inference is "on a per module basis". Moving a function to its own module produces
      `This value is "aliased" but expected to be "unique".`
    - A for-loop cannot close over a unique value.
    - Writes in place ("overwriting") are still not implemented.
- **Hylo.**
  - **[Language tour: bindings](https://docs.hylo-lang.org/language-tour/bindings).**
    - **The rule.** A consuming use "must be the last use".
    - **The error.** "`weight` used after being consumed here", with an arrow to the consuming
      site.
    - **The fix offered.** The compiler "will suggest that you change the code to consume
      copies … and will offer to insert these copies for you".
    - **On noise.** "Copies are explicit by default … explicit copies in code are always salient
      rather than 'noisy'". A scoped `@implicitcopy` opts out.
    - **For beni.** This is the nearest shipped shape to the owner's proposal. Its conventions
      are written on signatures, though.
  - **Racordon, Shabalin, Zheng, Abrahams, Saeta, "Implementation Strategies for Mutable Value
    Semantics", JOT 21(2), 2022.** [PDF](https://www.jot.fm/issues/issue_2022_02/article2.pdf).
    - Arrays use copy-on-write.
    - Swift was slower than C++ "only for programs with extremely large number of mutating
      operations (> 90%)".
    - Nested arrays force a caller-side copy.
  - **Racordon & Abrahams, "Borrow checking Hylo", IWACO 2023.**
    [Page](https://2023.splashcon.org/details/iwaco-2023-papers/5/Borrow-checking-Hylo)
    (paper not read).
    - An abstract interpreter over lifetimes.
    - No false-positive account.
  - **Dave Abrahams, "Value Semantics: Safety, Independence, Projection, & Future of
    Programming", CppCon 2022.** [Video](https://youtu.be/QTLn3goa3A8) **[unverified: link from
    search, not watched]**.
- **Swift.**
  - **[Ownership Manifesto](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md),
    John McCall, 2017.**
    - "Programmers should be able to largely ignore ownership and not suffer for it. If this
      expectation proves to not be satisfiable, we will reject ownership rather than imposing
      substantial burdens on regular programs."
    - Its section *Explicitly-copyable types* is close to the owner's idea: "the compiler should
      diagnose any implicit copies … it should be possible to request a copy with the `copy`
      function".
  - **[SE-0377](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md).**
    - A `borrowing` or `consuming` parameter is "no longer implicitly copyable".
    - The rule was deliberately *not* made transitive, because otherwise developers "would only
      be able to use them … bottom-up from leaf functions".
  - **["Explicit copies mode"](https://forums.swift.org/t/explicit-copies-mode/81779), Swift
    forums, 2025.** The closest real debate to the owner's proposal.
    - Kavon Farvardin: diagnostics must not "change based on the optimization level".
    - John McCall: guarantee elision "in some core set of situations… That core set… could grow
      over time, but never shrink… these guarantees would have to be real guarantees… even in
      debug builds. It would be very short-sighted to define the set… by what -O is able to
      eliminate."
    - David Nadoba, on a three-copy example: "we end up with at least 2 out of 3 false
      positives". This is one worked example, not a measurement.
  - **[Swift 5 exclusivity enforcement](https://www.swift.org/blog/swift-5-exclusivity/), 2019.**
    - Static checks "catch many common exclusivity violations", but run-time checks are
      "required" for "escaping closures, properties of class types, static properties, and
      global variables".
    - Swift's static checking stops exactly at closures and stored references.

### 2.4 Silent-fallback systems: what their inference achieves

These are not the owner's design. Each tells how far a precise inference gets before it falls
back.

- **Reinking, Xie, de Moura, Leijen, "Perceus", PLDI 2021.**
  [DOI](https://doi.org/10.1145/3453483.3454032),
  [TR](https://www.microsoft.com/en-us/research/uploads/prod/2020/11/perceus-tr-v4.pdf).
  - Thesis: "a combination of static compiler optimizations with dynamic runtime checks … are
    needed for best results".
  - Nothing counts how often an update happens in place.
- **Lorenzen & Leijen, "Reference Counting with Frame Limited Reuse", ICFP 2022.**
  [DOI](https://doi.org/10.1145/3547634).
  - **The earlier analyses were flawed (§3).** "Both previously published algorithms for reuse
    analysis are flawed". Koka's "is fragile with respect to small program transformations".
    Lean's "can lead to an arbitrary increase in peak memory usage".
  - **No borrow inference (§4).** "Koka currently has no automatic borrow inference."
  - **For beni.** A rule tied to an optimiser-shaped analysis can flip when the inliner changes.
    This is McCall's point again.
- **Lorenzen, Leijen, Swierstra, "FP²: Fully in-Place Functional Programming", ICFP 2023.**
  [DOI](https://doi.org/10.1145/3607840),
  [TR](https://www.microsoft.com/en-us/research/uploads/prod/2023/05/fip-tr-v2.pdf).
  - **Why they rejected uniqueness types (§1.4.1).** "It leads to code duplication, where a
    single function can have multiple different implementations: one version taking a unique
    argument; and one taking a shared argument." The example is two `reverse` functions.
  - **Call sites are not checked.** Deciding which calls are safe "requires further information
    about how arguments are shared at call sites". `palindrome xs = append(xs, reverse(xs))` is
    exactly beni's case.
  - **Not a type system.** FIP linearity is syntactic, "much simpler to specify and implement"
    than linear types.
  - **For beni.** Clean avoids the duplication by letting a function's types say "works on unique
    or shared lists". Beni would need that, or one `reverse` per mode.
- **Lorenzen, Leijen, Swierstra, Lindley, "The Functional Essence of Imperative Binary Search
  Trees", PLDI 2024.** [DOI](https://doi.org/10.1145/3656398) (abstract only).
  - `fip` trees run "on par with the fastest implementations in C".
  - Still decided by a run-time reference count of 1.
- **Koka's JavaScript backend.** [Koka source](https://github.com/koka-lang/koka).
  - Perceus and reuse (`Parc.hs`, `ParcReuse.hs`) are called only from the C backend.
  - `lib/std/core/inline/vector.js` copies on every write: `// make copy :-(`.
  - **For beni.** The only language with both FBIP and a JS target does not do in-place updates
    on JS.
- **Lean 4.**
  - **Ullrich & de Moura, "Counting Immutable Beans", IFL 2019.**
    [arXiv](https://arxiv.org/abs/1908.05647). Its §5.2 algorithm:
    - every parameter starts borrowed;
    - a parameter becomes owned when it reaches a `reset` or an owned position;
    - each recursive group is iterated to a fixpoint;
    - inference exists for "avoiding the burden of annotations".
  - **[lean4#12413](https://github.com/leanprover/lean4/pull/12413)** (merged 2026-02-11). Borrow
    inference was ported to the new compiler as `LCNF/InferBorrow.lean`.
    - Exported functions start all-owned, a fixed boundary like OxCaml's interfaces.
    - The performance heuristics yield to a user's own annotation.
  - **Huisinga, *Static Uniqueness Analysis for the Lean 4 Theorem Prover*, MSc thesis, KIT
    2023.** [PDF](https://pp.ipd.kit.edu/uploads/publikationen/huisinga23masterarbeit.pdf).
    - Its `Array.groupBy` was "accidentally quadratic" because a group stayed inside an `RBMap`
      while being pushed to.
    - §8: no higher-order functions, no inference, no attribute polymorphism, and
      "non-satisfactory results on recursive functions over recursive types".
- **Roc.**
  - **[Zulip, "explicit move semantics?"](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/explicit.20move.20semantics.3F/near/305822253)**
    (Ayaz Hafiz, 2022, second-hand). Uniqueness types "were removed because they were deemed to
    be a net negative".
    - In the same thread a user asked for exactly the beni rule, opt-in: "an attribute that
      reports me an error if the optimization cannot be done".
  - **[Zulip, "Ensure Unique"](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Ensure.20Unique/near/277650069)**
    (2022).
    - Hansknecht: "By default we infer not guaranteed unique which is always correct. If
      specified as unique it propagates and fails to type check".
    - Folkert de Vries: "uniqueness as something that is lost … there is no way to 'just' regain
      it … you can essentially clone a value".
    - The opt-in design, kept as an idea.
  - **[Zulip, "remove morphic?"](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/remove.20morphic.3F)**
    (2025).
    - Static in-place updates gave 3.13 ± 0.08× on a `List.set` loop over the run-time check.
    - Feldman: "if we didn't have it in the compiler right now, I don't think we'd add it".
  - **[roc-lang.org/functional](https://www.roc-lang.org/functional)**, as of 2024 (Wayback).
    - Automatic cloning "can also increase unintentional cloning".
    - The current page instead offers explicit local `var $x`.
  - **Richard Feldman, "Outperforming Imperative with Pure Functional Languages", Strange Loop
    2021.** [Video](https://www.youtube.com/watch?v=vzfy4EKwG_Y) (title verified, not watched).
- **Brandon, Driscoll, Dai, Ragan-Kelley, Milano, Aiken, "Fully-Automatic Type Inference for
  Borrows with Lifetimes", OOPSLA 2026.** [DOI](https://doi.org/10.1145/3798221),
  [abstract](https://2026.splashcon.org/details/oopsla-2026/22/Fully-Automatic-Type-Inference-for-Borrows-with-Lifetimes)
  **[abstract only: the ACM page answers 403 and the PDF 404]**.
  - Programs inference "cannot … type" get "a handful of reference count operations".
  - Against Perceus: "75-100%" fewer increments, "1.48x geomean".
  - **The figure beni needs, the rate of fallback sites, is not in the abstract.** Every fallback
    would be an error under the owner's rule.

### 2.5 Recent research on tracking sharing (2021–2026)

- **Emre, Boyland, Parekh, Schroeder, Dewey, Hardekopf, "Aliasing Limits on Translating C to
  Safe Rust", OOPSLA 2023.** [PDF](https://www.cs.usfca.edu/~memre/oopsla23-aliasing-limits.pdf).
  - **Imprecision spreads.** "Having only 4 pointers marked unsafe is enough to force 85% of the
    4,635 pointers in the program to be marked unsafe" (tmux, §1). "The four largest equivalence
    classes account for 85% of the raw pointers in all benchmarks."
  - **The fix.** Field sensitivity "does not substantially improve over the baseline", while
    subset-based and context-sensitive analyses "each individually improve the baseline by an
    order of magnitude".
  - **For beni.** This is the single most useful measured result here: it prices
    unification-based alias inference and says what to use instead.
- **Bao, Wei, Bračevac, Jiang, He, Rompf, "Reachability Types", OOPSLA 2021.**
  [PDF](https://www.cs.purdue.edu/homes/rompf/papers/bao-oopsla21.pdf).
  - Tracks "sharing and separation through reachability sets", and layers "uniqueness on top"
    where needed.
  - Sharing is allowed and tracked; uniqueness is demanded only at the update. That is the
    owner's rule as a type system.
- **Wei, Bračevac, Jia, Bao, Rompf, "Polymorphic Reachability Types", POPL 2024.**
  [arXiv](https://arxiv.org/abs/2307.13844).
  - Naive polymorphic extensions "are unsound".
  - The fix tracks one-step reachability and closes it transitively only when needed. That is
    the polymorphism problem Futhark hit, solved in theory.
- **Jia, Wei, He, Bao, Rompf, "Escape with Your Self", PLDI 2026.**
  [arXiv](https://arxiv.org/abs/2404.08217).
  - "An outstanding problem with reachability types is algorithmic type checking and inference."
  - It gives a decidable bidirectional algorithm, checked in Lean, that "infers qualifiers via a
    lightweight unification mechanism".
  - It is the most current answer on how far inference goes for sharing in higher-order code.
    Whether top-level signatures still need qualifiers is **[unverified: full text not read]**.
- **Bračevac, Wei, Jia, Abeysinghe, Jiang, Bao, Rompf, "Graph IRs for Impure Higher-Order
  Languages", OOPSLA 2023.** [PDF](https://www.cs.purdue.edu/~rompf/papers/bracevac-oopsla23.pdf).
  - Reachability types in a compiler IR with separate compilation. This is the compiler-side
    version of the same work.
- **Xu, Bračevac, Pham, Zhao, Odersky, "System Capybara", arXiv 2026.**
  [arXiv](https://arxiv.org/abs/2607.09383). Scala 3's separation checker.
  - **Inference.** "Most permissions are inferred", and a `consume` "kills its aliases".
  - **Freezing.** §6.2 turns a mutable buffer into an immutable one through a `consume`
    parameter. This is a clean model of `List.copy`'s opposite.
  - **No figures (§7).** "We have not measured the annotation cost", and "a component of a
    shared structure therefore cannot be consumed directly".
- **Boruch-Gruszecki, Odersky, Lee, Lhoták, Brachthäuser, "Capturing Types", TOPLAS 2023.**
  [PDF](https://plg.uwaterloo.ca/~olhotak/pubs/toplas23.pdf).
  - The calculus under Capybara.
  - It has been applied to much of Scala's standard library, with no figures.
- **Spiwack, Kiss, Bernardy, Wu, Eisenberg, "Linearly Qualified Types", ICFP 2022.**
  [DOI](https://doi.org/10.1145/3547626); revised as
  [arXiv 2604.21467](https://arxiv.org/abs/2604.21467) (2026).
  - Linear capabilities become implicit arguments "filled in automatically by the compiler"
    through GHC's constraint solver.
  - It keeps uniqueness out of signatures by constraint solving, not annotation.
- **O'Connor, Linares Arévalo, Rizkallah, "Uniqueness is Separation", arXiv 2026.**
  [arXiv](https://arxiv.org/abs/2602.06386).
  - From the Cogent group: uniqueness works "by statically ruling out every program where the
    difference between the immutable and the mutable interpretations can be observed".
  - That sentence is the contract a beni error states. It is the right thing to explain to the
    user.
- **Marshall & Orchard, "Functional Ownership through Fractional Uniqueness", OOPSLA 2024.**
  [arXiv](https://arxiv.org/abs/2310.18166).
  - Rust's ownership "arises as a graded generalisation of uniqueness".
  - Explicit by choice, "rather than using a complex static analysis like Rust's borrow checker
    to infer which programs are safe". Theory only, with no inference results.
- **Ho, Fromherz, Protzenko, "Sound Borrow-Checking for Rust via Symbolic Semantics", ICFP
  2024.** [arXiv](https://arxiv.org/abs/2404.02680).
  - Borrow checking as symbolic execution with a join at loops, proved sound.
  - It models how to state "what the checker knows" at each point.
- **Villani, Hostert, Dreyer, Jung, "Tree Borrows", PLDI 2025.**
  [DOI](https://doi.org/10.1145/3735592).
  - A dynamic aliasing model for unsafe Rust that "rejects 54% fewer test cases than Stacked
    Borrows" on the 30,000 most-downloaded crates.
  - **For beni.** A simpler, stricter aliasing rule rejected a large measured share of code
    people consider correct.
- **Stjerna, *Modelling Rust's Reference Ownership Analysis Declaratively in Datalog*, MSc
  thesis, Uppsala 2019.** [PDF](https://rust-lang.zulipchat.com/user_uploads/4715/wo3Mo_EQ9MKiWGbd2qI-sMn4/Thesis.pdf).
  - Over about 12,000 repositories and 3.9 million functions, "circa 64%" create no references
    at all.
  - "A weaker (and therefore faster) analysis than Polonius is often sufficient."
  - **For beni.** Run a cheap check first and the precise one only where the cheap one fails.
- **Ma & Foster, "Uno: Inferring Aliasing and Encapsulation Properties for Java", OOPSLA 2007.**
  **[unverified: abstract seen through search only]**.
  - Annotation-free.
  - Found that lending a reference to a method is common, while owned fields and arguments are
    "relatively uncommon".

### 2.6 Linear Haskell, Granule and Idris: retrospectives

- **Arnaud Spiwack, Tweag.** ["Linear Constraints: the problem with O(1) freeze"](https://tweag.io/blog/2023-01-26-linear-constraints-freeze/)
  (2023) and ["… the problem with scopes"](https://tweag.io/blog/2023-03-23-linear-constraints-linearly/)
  (2023).
  - In linear-base, n linear types need n² `newXBeside` functions. "This is simply not
    sustainable … one of the longest standing issues in linear-base."
  - **For beni.** A *visible* linearity discipline grows the API quadratically; the owner's rule
    escapes this only if uniqueness stays invisible.
- **Granule.** Marshall & Orchard (above). Explicit graded types; no inference evidence.
- **Idris 1 uniqueness types.**
  [Docs](https://idris.readthedocs.io/en/v0.9.19/reference/uniqueness-types.html).
  - "An experimental feature"; error text "Unique name xs is used more than once".
  - Edwin Brady on HN ([8514760](https://news.ycombinator.com/item?id=8514760)): "It's hard to
    write something that's generic over a uniqueness type and a normal type".
  - Idris 2 replaced them with quantities written in signatures.

### 2.7 Surveys

- **Clarke, Östlund, Sergey, Wrigstad, "Ownership Types: A Survey", LNCS 7850, 2013.**
  [DOI](https://doi.org/10.1007/978-3-642-36946-9_3),
  [PDF](https://ilyasergey.net/papers/ownership-survey.pdf).
  - **Why inference disappoints (§5).** Inference finds "any solution that satisfies the
    constraints, but cannot give a best solution". Beni must find the *most unique* solution.
  - **§8.** "State-of-the-art ownership inference is not good enough to do this fully
    automatically."
  - **Case studies.** In AliasJava, "most method parameters were annotated with lent and many
    return values … unique". A 50 kLOC Universes case study needed "replacing pass-by-reference
    by pass-by-copy", the object-oriented analogue of `List.copy`.
- **Noble, Vitek, Potter, "Flexible alias protection", ECOOP 1998.**
  [DOI](https://doi.org/10.1007/bfb0054091). The origin of ownership types.
- No standalone survey of uniqueness and linear types in *functional* languages was found.

### 2.8 Measured friction: what false and true ownership errors cost people

- **Crichton, Gray, Krishnamurthi, "A Grounded Conceptual Model for Ownership Types in Rust",
  OOPSLA 2023.** [PDF](https://cs.brown.edu/~sk/Publications/Papers/Published/cgk-grounded-model-rust-ownership/paper.pdf).
  - **Understanding is not fixing (§2.4).** Learners "could usually predict why the borrow
    checker would reject a program … However, participants could only fix the program in 46% of
    cases … and could only create a counterexample in 31% of cases."
  - **Safe programs look unsafe.** "Only 3/15 participants" saw that a rejected `reverse` was
    actually safe.
  - **`clone` as the fix.** A common fix was "using clone to satisfy the borrow checker".
  - **Better teaching helps.** It lifted scores "from 48% to 57% (N = 342 … d = 0.56)".
  - **For beni.** An error should say what would go wrong if the update ran in place, and should
    say when the rejection is only the checker's limit.
- **Crichton, "The Usability of Ownership", HATRA 2020.** [arXiv](https://arxiv.org/abs/2011.06171).
  - Errors "may arise from either ownership-unsound behavior or limitations of the analyzer.
    Understanding this distinction is essential for fixing ownership errors."
  - The rewrites out of the "incompleteness zone" are "a dark, perverse bag of tricks".
- **Crichton & Krishnamurthi, "Profiling Programming Language Learning", OOPSLA 2024.**
  [arXiv](https://arxiv.org/abs/2401.01257).
  - Data: 62,526 readers and 1,140,202 answers.
  - "Chapter 4 [Ownership] is a significant drop-off point."
  - **For beni.** If the error fires in a beginner's first `update`, it becomes the drop-off.
- **Zhu, Zhang, Qin, Xiong, Song, "Learning and Programming Challenges of Rust", ICSE 2022.**
  [PDF](https://par.nsf.gov/servlets/purl/10321050).
  - **Stack Overflow.** 23% of sampled questions came from not understanding the safety rules.
  - **Survey.** 39.6% "always" understood ownership errors, against 10.0% for lifetime errors.
  - **No fix.** 8 of 118 violations had "no fix" because the programmer's intent conflicts
    with the rule.
  - "The Rust compiler may not provide all information necessary to comprehend violations."
  - **For beni.** It has no lifetimes for users to compute, which avoids the worst of these
    numbers.
- **Coblenz et al., "Garbage Collection Makes Rust Easier to Use", ICSE 2022.**
  [arXiv](https://arxiv.org/abs/2110.01098).
  - A randomised trial with 428 students.
  - On an aliasing-heavy task, GC users were more likely to finish and "required only about a
    third as much time (4 hours vs. 12 hours)".
- **Fulton, Chan, Votipka, Hicks, Mazurek, "Benefits and Drawbacks of Adopting a Secure
  Programming Language: Rust as a Case Study", SOUPS 2021.**
  [PDF](https://par.nsf.gov/servlets/purl/10357735).
  - 59% of surveyed users found Rust harder to learn.
  - Time to code that compiles without frequent `unsafe`: 27% under a week, 41% up to a month,
    25% up to six months.
- **JetBrains, "The most common Rust compiler errors as encountered in RustRover", 2023.**
  [Part 1](https://blog.jetbrains.com/rust/2023/12/14/the-most-common-rust-compiler-errors-as-encountered-in-rustrover-part-1/).
  - E0382 (use after move) reached 17% of users and ranks sixth.
  - The top five are type and trait errors.
  - 8 of the top 25 are ownership or lifetime errors.
  - **For beni.** Common, but not dominant, once an editor gives feedback.
- **Rust surveys.**
  - [2020](https://blog.rust-lang.org/2020/12/16/rust-survey-2020/): "61.4%" find lifetimes
    tricky or very difficult.
  - [2024](https://blog.rust-lang.org/2025/02/13/2024-State-Of-Rust-Survey-results/): no
    borrow-checker breakdown.
- **NLL and Polonius.** [NLL by default](https://blog.rust-lang.org/2022/08/05/nll-by-default/)
  (2022) and the [Polonius update](https://blog.rust-lang.org/inside-rust/2023/10/06/polonius-update/)
  (2023).
  - **No crater counts** of programs newly accepted were published.
  - Matsakis on a still-rejected program: "This example doesn't compile today… though there's
    not a good reason for that."
- **Zhang et al., "Effects of Enhanced Compiler Error Messages in Rust", ACSAC 2021 poster.**
  **[unverified: search record only]**.
  - N = 52.
  - Messages that show the solution helped more than messages that explain.

### 2.9 Error-message design

- **Evan Czaplicki, ["Compiler Errors for Humans"](https://elm-lang.org/news/compiler-errors-for-humans),
  2015.**
  - Show the code as written and explain the problem in the user's terms; "Every message has a
    useful hint".
  - **Cost note.** It needed "no significant changes to the type inference algorithm … I just
    added an extra bit of info to each type constraint".
  - **For beni.** Storing *where the old version was kept* on each uniqueness fact is the same
    trick.
- **Czaplicki, ["Compilers as Assistants"](https://elm-lang.org/news/compilers-as-assistants),
  2015.**
  - "A compiler should not just *detect* bugs, it should then help you understand *why*."
  - The [error-message catalog](https://github.com/elm/error-message-catalog) is the process to
    copy: one catalogued program per error shape.
- **Turner, ["Shape of errors to come"](https://blog.rust-lang.org/2016/08/10/Shape-of-errors-to-come/),
  Rust blog, 2016.**
  - A primary label says *what* went wrong; secondary labels say *why*, in source order.
  - Its showcase is a borrow error.
  - It credits Elm.
- **[rustc-dev-guide, diagnostics](https://rustc-dev-guide.rust-lang.org/diagnostics.html).**
  - Succinct, because users "will see these error messages many times".
  - `help` shows a change the user can make; "'did you mean' should be avoided"; "The word
    'illegal' is illegal".
  - Every suggestion carries an applicability level. A `List.copy` fix would be
    machine-applicable.
- **[E0382](https://doc.rust-lang.org/error_codes/E0382.html).**
  - States the rule in one sentence, then lists fixes in order: borrow, `clone`, `Rc`.
- **Futhark's message history**
  ([2021 post](https://futhark-lang.org/blog/2021-05-11-anatomy-of-a-type-checker-bug.html)).
  - Before: `Consuming "internal_app_result", but this was previously consumed at 4:7-10.`
  - After: `Consuming result of applying "iota" (at 2:23-28), but this was previously consumed
    at 4:7-10.`
  - Name unnamed intermediate results in the user's terms.
- **OxCaml's hint form.** `This value is "aliased" but expected to be "unique".`, then
  `Hint: This identifier cannot be used uniquely, because it was defined outside of the
  for-loop.` A short statement, then a *because*.
- **Clean, the counter-example.**
  - `demanded attribute cannot be offered by shared object`.
  - The equality-based draft's "too unique (please use it more than once)".
  - Both speak in the type system's terms and never name the other holder.
- **Barik, Smith, Lubick, Holmes, Feng, Murphy-Hill, Parnin, "Do Developers Read Compiler Error
  Messages?", ICSE 2017.** [DOI](https://doi.org/10.1109/icse.2017.59) **[read via a summary,
  not the paper]**.
  - Eye-tracking, N = 56.
  - Reading error messages took 13–25% of task time, and how hard they were to read predicted
    task performance.
- **Barik et al., "How should compilers explain problems to developers?", ESEC/FSE 2018.**
  [DOI](https://doi.org/10.1145/3236024.3236040) **[read via a summary]**.
  - Developers "will accept a deficient argument structure if it provides a resolution". The
    fix outweighs the explanation.
- **Becker et al., "Compiler Error Messages Considered Unhelpful", ITiCSE-WGR 2019.**
  [DOI](https://doi.org/10.1145/3344429.3372508) **[read via a summary]**.
  - Ten guidelines, among them: provide context, show solutions or hints, report at the right
    time.
- **Mixed evidence on rewording.**
  - Denny, Luxton-Reilly, Carpenter, ITiCSE 2014 ([DOI](https://doi.org/10.1145/2591708.2591748)):
    enhanced syntax messages had no significant effect on 83 students.
  - Becker, SIGCSE 2016: about 200 students and 50,000 errors, with fewer errors and fewer
    repeats **[search record only]**.
  - **For beni.** Rewording alone is not guaranteed; test messages on real programs.
- **Wrenn & Krishnamurthi, ["Error Messages Are Classifiers"](https://cs.brown.edu/~sk/Publications/Papers/Published/wk-error-msg-classifier/),
  Onward! 2017.**
  - "Error reports are really *classifiers* … subjected to the same measures as other
    classifiers (e.g., precision and recall)."
  - This is the frame for the owner's question: count the false errors over `core/` and the
    corpus.
- **Marceau, Fisler, Krishnamurthi, ["Mind Your Language"](https://cs.brown.edu/~sk/Publications/Papers/Published/mfk-mind-lang-novice-inter-error-msg/),
  Onward! 2011.**
  - Both the text and the highlighted location matter.
- **Esteban Küber, "Friendly Ferris: Developing Kind Compiler Errors", RustLatam 2019.**
  [Video](https://av.tib.eu/media/52176).

### 2.10 Designers on why they chose or rejected uniqueness errors

- **Graydon Hoare, ["The Rust I Wanted Had No Future"](https://graydon2.dreamwidth.org/307291.html),
  2023.** The page blocks scripted fetches; it was verified through the Web Archive.
  - "I wanted & to be a 'second-class' parameter-passing mode … I think the cognitive load
    doesn't cover the benefits."
  - On lifetimes: "They were supposed to all be inferred, and they're not".
- **Steve Klabnik, ["Rust's Golden Rule"](https://steveklabnik.com/writing/rusts-golden-rule),
  2023.**
  - "Rust does not infer function signatures. If it did, changing the body of the function would
    change its signature."
  - **For beni.** It must decide whether an inferred "consumes its argument" fact is part of a
    module's public contract.
- **"prophet", "Functional programming languages should be so much better at mutation than they
  are", cohost, 2024.** [Archive](https://web.archive.org/web/20241231000000*/cohost.org/prophet/post/7083950)
  **[the original site is gone; this pass read a December 2024 Web Archive snapshot, and the
  link is the archive's index of snapshots]**;
  [HN 41106280](https://news.ycombinator.com/item?id=41106280).
  - Opt-in linearity "inevitably creates a parallel, incomplete universe of functions".
  - Linearity by default makes "changing a function from using an argument linearly to
    non-linearly … a breaking change".
  - Reference-count fallback needs reference counts, and "a tracing garbage collector just
    doesn't give you this sort of information".
  - **For beni.** JavaScript's collector cannot supply the fallback Roc and Koka rely on.
- **Stephen Dolan with Ron Minsky, ["Memory Management"](https://signalsandthreads.com/memory-management/),
  Signals & Threads, 2022.**
  - Rust's annotation weight is "certainly not appropriate for OCaml".
  - OxCaml modes have "no variables and no polymorphism … So the type inference story works out a
    lot more simply".
  - In hard cases "we haven't thrown away the garbage collector". OxCaml's escape valve is a
    fallback, not an error.
- **Fernando Borretti, [Austral](https://borretti.me/article/introducing-austral) (2022) and
  ["Type Systems for Memory Safety"](https://borretti.me/article/type-systems-memory-safety)
  (2023).**
  - Complexity is "more or less proportional to how easy it is to write code that 'does what you
    mean' and have it compile".
  - On HN, dureuill answers from Rust's move to non-lexical lifetimes, the borrow checker that
    tracks where a borrow actually ends: "from a user's point of view it is worth all the
    complexity in the rules" ([34230696](https://news.ycombinator.com/item?id=34230696)).
- **Evan Ovadia (Vale).** ["What Vale Taught Me About Linear Types, Borrowing, and Memory
  Safety"](https://verdagon.dev/blog/linear-types-borrowing) (2023);
  ["Borrow checking, RC, GC, and the Eleven (!) Other Memory Safety Approaches"](https://verdagon.dev/grimoire/grimoire)
  (2024).
  - Borrow checking imposes "upwardly viral constraints" and needs data to be sliced "in
    unintuitive ways".
- **Aaron Turon, ["Rust's language ergonomics initiative"](https://blog.rust-lang.org/2017/03/02/lang-ergonomics/),
  2017.**
  - An implicit feature should be limited in two of applicability, power and context-dependence
    if it is large in the third.
  - An inferred uniqueness rule is large in context-dependence: whether this line is accepted
    depends on code elsewhere.
- **Niko Matsakis, ["Claiming, auto and otherwise"](https://smallcultfollowing.com/babysteps/blog/2024/06/21/claim-auto-and-otherwise/),
  2024.**
  - Explicit `clone` is "visual clutter", while implicit large copies are a footgun.
  - The tension `List.copy` would live in.
- **[Koka book, FBIP](https://koka-lang.github.io/koka/doc/book.html).**
  - "We'd like to add ways to add annotations to ensure reuse is taking place". That became
    `fip`, which warns.
- **Hacker News, practitioners.**
  - throwaway17_17 on FIP: "no annotation burden or conceptual distinction to be made by users"
    ([46696702](https://news.ycombinator.com/item?id=46696702)).
  - pornel: Rust "can't abstract over mutability … separate `foo()` and `foo_mut()`"
    ([41113725](https://news.ycombinator.com/item?id=41113725)).
  - 2026 "fighting the borrow checker" threads converge on "clone liberally"
    ([47757798](https://news.ycombinator.com/item?id=47757798)).
  - Again, no first-hand report of a performance cliff from accidental sharing in Roc, Koka or
    Lean was found. The cliff is documented by the designers, not reported by users.

### 2.11 The JavaScript angle

- **Immer** (Michel Weststrate, 2018–).
  - [Introduction](https://immerjs.github.io/immer/): drafts are copied lazily along the touched
    path, and "Immer will detect accidental mutations and throw an error".
  - [Pitfalls](https://immerjs.github.io/immer/pitfalls): "Data that comes from the closure, and
    not from the base state, will never be drafted". This is the closure hole again.
  - [Performance](https://immerjs.github.io/immer/performance): "roughly … twice to three times
    slower as a handwritten reducer".
  - [v8.0.0](https://github.com/immerjs/immer/releases/tag/v8.0.0) (2020) freezes in production
    too. [Weststrate](https://github.com/immerjs/immer/issues/687#issuecomment-728881754): "not
    freezing made things 8 times slower".
  - **For beni.** The JS answer to "nobody mutates the old version" is a deep freeze shipped to
    production; a compile-time rule removes that cost.
- **[Mutative](https://github.com/unadlib/mutative)** (current README). Microseconds per update,
  hand-written versus drafts:
  - update every row of 10,000: 211 hand-written, against 6,629 for Mutative and 9,783 for
    Immer;
  - an update by ID in 100 rows: 1.73 for Immer, 25.2 for Immer with auto-freeze.

  This is the run-time cost a static rule would avoid.
- **Immutable.js `withMutations` / `asMutable`.** [Source](https://github.com/immutable-js/immutable-js).
  - Each trie node carries the `ownerID` of the session that made it, and is edited in place
    only by that owner.
  - Misuse is not detected; the docs only warn, "must no longer be mutated".
- **Clojure transients.** [Reference](https://clojure.org/reference/transients), Rich Hickey.
  - "Not designed to be bashed in-place".
  - 1,000,000 elements: 8.4 ms persistent, 5.5 ms transient.
  - The thread-ownership check "was removed in 1.7".
  - The only remaining check is use after `persistent!`.
  - The JVM source shows that ignoring a return value silently loses writes once the array-map
    becomes a hash map.
- **ClojureScript and [Mori](https://github.com/swannodette/mori).**
  - The same edit-token scheme, using `(js-obj)`.
  - "conj! after persistent!" errors.
- **[Gren](https://gren-lang.org/news/240826_gren_045)** (Robin Heggelund Hansen's Elm fork).
  - Arrays are plain JS arrays, and `set` is `array.with(i, v)`, a full copy.
  - Its `Array.Builder` "uses mutation under the hood, but it isn't observable": a sticky
    `__$finalized` bit makes a reused builder silently `slice`.
  - That is research 42's R2 with a silent copy, the fallback the owner wants to forbid.
- **Elm.** [elm/core](https://github.com/elm/core).
  - `_JsArray_unsafeSet` copies the array; mutation happens only during construction.
  - [elm-optimize-level-2](https://github.com/mdgriffith/elm-optimize-level-2/blob/master/notes/transformations.md):
    "we need to copy the entire record so that it has a new reference". Elm's identity
    constraint is the same as beni's.
- **PureScript.** [purescript-arrays](https://github.com/purescript/purescript-arrays).
  - Safe mutation is scoped by `ST`.
  - `unsafeThaw` and `unsafeFreeze` are unchecked ("must not be used afterward").
  - [purescript-backend-optimizer](https://github.com/aristanetworks/purescript-backend-optimizer)
    does no uniqueness analysis.
- **ReScript, Melange, Fable.**
  - [ReScript](https://rescript-lang.org/docs/manual/array-and-list),
    [Melange](https://melange.re/v5.0.0/data-types-and-runtime-rep.html) and
    [Fable](https://fable.io/docs/javascript/compatibility.html) hand users mutable JS arrays.
  - Nothing is checked.
- **Gleam's JS target.** [Prelude](https://github.com/gleam-lang/gleam).
  - `List` is a linked list, with no in-place path.
- **Not checked: Scala.js, js_of_ocaml, Idris 2's JS backend.** Grain targets WebAssembly, not
  JS.
- **React.** ["Updating Arrays in State"](https://react.dev/learn/updating-arrays-in-state) and
  [`useState`](https://react.dev/reference/react/useState).
  - "React will ignore your update if the next state is equal to the previous state, as
    determined by an `Object.is` comparison. This usually happens when you change an object or
    an array in state directly."
  - **For beni.** In-place mutation of a value the renderer kept is dropped silently. The same
    would hold for beni's DOM runtime, which checks identity per hole (CLAUDE.md rule 8).
- **Redux.**
  - The [style guide](https://redux.js.org/style-guide/) calls mutation "the most common cause
    of bugs … and will also break time-travel debugging". Time travel is an undo history.
  - [Writing reducers with Immer](https://redux.js.org/toolkit/usage/immer-reducers): "the single
    most common mistake Redux users make".
  - [redux#2858](https://github.com/reduxjs/redux/issues/2858) explains why core Redux refused a
    freeze check: "performance penalties and impacts correctness (we can't just enable it in DEV
    and disable in PROD because the behavior would be different)".
- **TC39.**
  - Records & Tuples were [withdrawn](https://github.com/tc39/proposal-record-tuple) in April
    2025.
  - [Composites](https://github.com/tc39/proposal-composites) are interned frozen objects, where
    "comparing them is just pointer equality".
  - Neither offers in-place update.

---

## 3. Measured figures

| Figure | What it measures | Population | Source |
|---|---|---|---|
| 4 of 293 copy sites (≈1.4%) undecidable; 25 (≈8.5%) real sharing; 264 removed | Static copy elimination; under the owner's rule, false errors and true errors | 5 Sisal programs, first-order numeric | [Cann, Feo, DeBoni 1990](https://www.osti.gov/servlets/purl/6569540), Table I and text |
| 114 and 347 ordering edges | Reads moved before writes to keep updates in place | Sisal Loops, SIMPLE | same |
| 4 unsafe pointers → 85% of 4,635 unsafe | Imprecision spreading through a unification-based alias analysis | tmux | [Emre et al. 2023](https://www.cs.usfca.edu/~memre/oopsla23-aliasing-limits.pdf) §1 |
| Order-of-magnitude improvement | Subset-based or context-sensitive analysis against unification-based | 16 C programs | same, §6 |
| 27,382 annotations in 2,648 of 187,765 `.mli` files | Mode annotations needed at interfaces (locality) | Jane Street, Feb 2024 | [Lorenzen et al. 2024](https://homepages.inf.ed.ac.uk/slindley/papers/mode-inference.pdf) §7 |
| 85 functions duplicated | Cost of having no mode polymorphism | Jane Street, Apr 2024 | same, §6.6 |
| ≈6,000 annotations in 80M lines | Annotations added only to fix type errors | Jane Street, Feb 2026 | [Mode Crossing](https://iris-project.org/pdfs/2026-icfp-modecrossing.pdf) §5 |
| 75–100% fewer RC increments; 1.48× | Inferred borrows against Perceus (fallback rate not given) | Benchmarks of the paper | [Brandon et al. 2026](https://doi.org/10.1145/3798221), abstract |
| 3.13 ± 0.08× | Static in-place `List.set` against a run-time RC check | Roc micro-benchmark | [Roc Zulip](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/remove.20morphic.3F) |
| 8.3×, 1.7× | Cost of losing in-place updates | Futhark k-means, tridag | [Henriksen thesis](https://futhark-lang.org/publications/troels-henriksen-phd-thesis.pdf) §10.1.5 |
| 0.159–0.636 of copying | Run time with destructive-update analysis | Yung's benchmarks | [Yung 1999](https://cs.nyu.edu/media/publications/yung_chung.pdf) Fig. 3.10 |
| ≈64% of functions | Create no references, so need no borrow analysis | 3.9M Rust functions | [Stjerna 2019](https://rust-lang.zulipchat.com/user_uploads/4715/wo3Mo_EQ9MKiWGbd2qI-sMn4/Thesis.pdf) |
| 54% fewer rejections | Precise against simpler aliasing model | 30,000 crates | [Tree Borrows](https://doi.org/10.1145/3735592) |
| 46% fixed; 31% counterexample; 78% predicted the reason | Learners handling borrow errors | 36 participants | [Crichton et al. 2023](https://cs.brown.edu/~sk/Publications/Papers/Published/cgk-grounded-model-rust-ownership/paper.pdf) §2.4–2.5 |
| 3 of 15 | Recognised a rejected program as safe | same | same, §2.4.1 |
| 48% → 57% | Ownership understanding after better teaching | N = 342 | same, §1 |
| Drop-off at ch. 4 | Readers leaving at the ownership chapter | 62,526 readers | [Crichton & Krishnamurthi 2024](https://arxiv.org/abs/2401.01257) |
| 39.6% vs 10.0% | "Always" understand ownership vs lifetime errors | 101 Rust users | [Zhu et al. 2022](https://par.nsf.gov/servlets/purl/10321050) §4 |
| 23%; 8 of 118 have no fix | Stack Overflow questions caused by safety rules; violations that conflict with intent | 100 sampled questions | same, §3 |
| 4 h vs 12 h | Aliasing task with GC vs borrow checker | 428 students, randomised | [Coblenz et al. 2022](https://arxiv.org/abs/2110.01098) |
| 59% | Found Rust harder to learn | 178 surveyed | [Fulton et al. 2021](https://par.nsf.gov/servlets/purl/10357735) |
| 17% of users; 8 of top 25 | Reach of E0382; ownership errors among the most common | RustRover telemetry | [JetBrains 2023](https://blog.jetbrains.com/rust/2023/12/14/the-most-common-rust-compiler-errors-as-encountered-in-rustrover-part-1/) |
| 61.4% | Lifetimes tricky or very difficult | Rust survey 2020 | [Rust blog](https://blog.rust-lang.org/2020/12/16/rust-survey-2020/) |
| 13–25% of task time | Spent reading compiler errors | N = 56 | Barik et al. 2017 (via summary) |
| "2 out of 3" | False positives in one worked example of an explicit-copies mode | one example, not a sample | [Swift forums 2025](https://forums.swift.org/t/explicit-copies-mode/81779) |
| 2–3× | Immer against a hand-written reducer | 50,000 todos, 5,000 updates | [Immer performance](https://immerjs.github.io/immer/performance) |
| 211 vs 9,783 µs; 1.73 vs 25.2 µs | Hand-written against Immer; Immer without and with freezing | Mutative's benchmark | [Mutative README](https://github.com/unadlib/mutative) |
| 8× | Slowdown from *not* freezing, which forces deep traversals | Immer issue #681 | [Weststrate 2020](https://github.com/immerjs/immer/issues/687#issuecomment-728881754) |

**What is missing.** No source gives a false-error rate for any inferred uniqueness or ownership
checker in a functional language, nor a count of how often Clean users annotate.

---

## 4. Reading list, by how much each would matter to a beni design

1. **Barendsen & Smetsers, "Uniqueness Type Inference" (PLILP 1995) and the MSCS 1996 paper.**
   The annotation-free recipe and its known false errors (`mark`, `foldr`).
2. **de Vries, Plasmeijer, Abrahamson, "Uniqueness Typing Simplified" (IFL 2007).** How to keep
   the demand in library types, how to handle partial application, and what still needs a rank-2
   annotation.
3. **Emre et al., "Aliasing Limits on Translating C to Safe Rust" (OOPSLA 2023).** Why the
   analysis must be directional and context-sensitive, with numbers.
4. **Futhark's 2026 aliasing post and 2022 uniqueness post.** The production experience,
   including the pipeline and polymorphism failure, and the free-theorem remedy.
5. **Aspinall, Hofmann, Konečný, "A type system with usage aspects" (JFP 2008).** Read-only
   aspects and the optimistic fixpoint that finds the best typing.
6. **Lorenzen et al., "Oxidizing OCaml" (ICFP 2024) with "Mode Crossing" (ICFP 2026).** Inference
   per module, interface annotations counted, and element types exempt.
7. **Crichton, Gray, Krishnamurthi (OOPSLA 2023) and Crichton (HATRA 2020).** What users cannot
   tell from an ownership error, and therefore what the message must say.
8. **Polymorphic Reachability Types (POPL 2024) and "Escape with Your Self" (PLDI 2026).** The
   current theory of inferred sharing in higher-order, polymorphic code.
9. **Cann, Feo, DeBoni 1990 (Sisal).** The only measured rate, read with its text.
10. **FP² (ICFP 2023) §1.4 and Frame-Limited Reuse §3–§4.** The code-duplication argument and
    why optimiser-shaped analyses make a fragile rule.
11. **Swift's "Explicit copies mode" thread and the Ownership Manifesto.** How a rule must be
    specified independently of the optimiser.
12. **Clarke et al., "Ownership Types: A Survey" §5 and §8.** Why inference must pick a *best*
    solution.
13. **Futhark's 2021 bug post, Elm's two 2015 posts and the rustc diagnostic guide.** How to word
    the error.
14. **React's and Redux's documentation on mutation.** What the failure looks like on beni's
    platform when nothing checks.
15. **Brandon et al. (OOPSLA 2026), once the full text is available.** Its fallback rate is the
    closest thing to a false-error rate for an inferred borrow system.

---

## 5. Open questions

1. **What is beni's own false-error rate?** Wrenn and Krishnamurthi's framing applies: count it.
   Prototype the analysis as a read-only pass over `core/` and `tests/corpus/` and classify every
   rejected update as real sharing or analysis limit, as Sisal's report did by hand. Nothing in
   the literature can stand in for that number.
2. **What does the TEA runtime do with the old model?** The DOM runtime keeps the model it
   rendered, so under a sound rule every list edited in `update` is shared. Can the runtime's
   hold be modelled as a borrow that ends before `update` runs (research 42 §0: "a runtime that
   hands the model over")? And does that survive identity-based change detection? React shows
   that in-place mutation of a kept value is silently dropped.
3. **Can a closure that only reads a captured list stay out of the way?** This is
   Aspinall–Hofmann's read-only aspect applied to higher-order code. Every source leaves it open,
   and it decides whether `List.map (λx → … xs …)` before `List.set xs …` is an error.
4. **How do polymorphic pipelines keep precision?** The candidates are Futhark's free-theorem
   idea and reachability types' one-step tracking. `▷` is beni's main idiom, so this matters
   more for beni than for Futhark.
5. **Is the summary part of a module's public contract?** It could be hashed into the interface
   so that a body edit can break callers (Klabnik), or frozen at `pub` boundaries as OxCaml and
   Lean do, which makes exports declare what they consume.
6. **One `reverse` or two?** FP²'s duplication argument says a function that consumes and one
   that shares are different functions. Clean answers with types that work on unique or shared
   lists. Which does beni's `core/List` take, and how does that look in a `where` clause?
7. **What does the message say?** Name three places:
   - where the old version is kept;
   - where it is edited;
   - where the old version is used later.

   Then state what the user would see go wrong, in plain words, and say whether this is certain
   sharing or the checker's limit. End with a machine-applicable `List.copy`. Build a catalogue
   of these programs, as Elm did, before the wording is fixed.
8. **Should the rule be monotone in the language's version?** McCall's condition was that the
   accepted set "could grow over time, but never shrink". A beni release that makes the analysis
   more precise must never reject a program the previous release accepted.
9. **Does Brandon et al.'s fallback count become an error count?** Their fallback sites are where
   a sound beni rule would report errors. Ask the authors for per-program counts.
