# Ownership, uniqueness and borrow checking: a reference library

This is the source material for a deep study of the theory and algorithms behind one possible
beni rule: **a compile error for editing a `List` while something else still holds the old
version**, with ownership inferred and no annotations in user code. Research
[68](../../docs/design/research/68-borrow-checking-and-ownership-survey.md) and
[69](../../docs/design/research/69-ownership-inference-deep-dive.md) surveyed who built what;
69 §1.3, §4 and §5 say what a precise rule would need and which questions are open. This
catalogue collects the papers, theses, documentation, posts, talks and checker source behind
those questions. It records what each item is and why it matters; it does not analyse them.

Collected 2026-10-10. 301 entries and 18 checker source locations.

| Section | Entries |
|---|---|
| 1. Foundations | 41 |
| 2. Uniqueness typing as built | 36 |
| 3. Inference algorithms | 77 |
| 4. Rust and its formal models | 37 |
| 5. Mutable value semantics and other languages | 58 |
| 6. Error messages for ownership | 28 |
| 7. Recent work (2023–2026) and other material | 24 |
| Checker source code | 18 |

## How to read an entry

Each entry gives its title, authors, venue and year, then three tags:

- **Type:** `paper`, `thesis`, `report`, `book`, `docs`, `spec`, `rfc`, `blog`, `talk`,
  `lecture`, `code` or `thread`.
- **Topics:** `foundations`, `uniqueness-built`, `inference`, `rust`, `mvs` (mutable value
  semantics and other languages), `errors` and `recent`, matching the sections. An entry is
  filed under one section, but its topics may name several.
- **Priority:** **core reading** (needed for the study), **supporting** (read when its topic
  comes up), **background** (context and history).

Then come its links:

- **Link** is the canonical address: a DOI, an arXiv page or the official documentation.
- **Open access** is a free copy from the authors, an open repository or the publisher, when
  the canonical link is not free.
- **Local copy** says whether there is a reading copy in this directory.
- **Note** records anything odd about the links, the copy or the facts.

Every link was checked on 2026-10-10. A DOI was checked against the DOI handle registry,
because ACM and Elsevier refuse scripted requests. Every other link returned 200, with
these exceptions:

- the Inko manual answers 403 to a browser user agent and 200 to plain curl;
- `cs.drexel.edu` serves an incomplete certificate chain;
- Trinity College Dublin's repository and eScholarship sit behind bot checks.

**[unverified]** marks an entry where a fact could not be confirmed: a venue, an author order,
a year, or an item known only from citations. The reason is given in its *Unverified* line.

## Local copies

The reading copies are git-ignored, so a fresh clone has none. Only this file is committed.

- `pdf/` holds open-access PDFs, named `year-firstauthor-short-title.pdf`; 144 files on
  2026-10-10.
  - Several old papers exist only as PostScript on the authors' pages. Their copies were
    converted to PDF.
  - Girard 1987 is a scan without a text layer.
- `text/` holds plain-text snapshots of blog posts, documentation pages and forum threads that
  may vanish; 109 files. Each starts with its source URL and the date it was saved.

The rules were:

- Copies came only from open sources: arXiv, the authors' pages, university repositories,
  open proceedings, and publisher open access.
- Nothing came from an unofficial mirror of a paywalled paper. A paywalled item is listed by
  its DOI with `Local copy: none`.
- Some items are free on ACM or ScienceDirect, but those sites refuse scripted downloads.
  They are marked in their notes, and a browser fetches them.

To fetch a missing copy again, download the entry's *Open access* link (or its *Link* when it is
a PDF) into `pdf/` under the name the entry gives.

## 1. Foundations

### Linear types can change the world!

Philip Wadler. IFIP TC 2 Working Conference on Programming Concepts and Methods, Sea of Galilee (North-Holland), 1990.  
`paper` · foundations, uniqueness-built · **core reading**

- Link: <https://homepages.inf.ed.ac.uk/wadler/topics/linear-logic.html>
- Open access: <https://homepages.inf.ed.ac.uk/wadler/papers/linear/linear.ps>
- Local copy: `pdf/1990-wadler-linear-types-can-change-the-world.pdf`
- Note: No DOI; published in Programming Concepts and Methods (IFIP TC 2, 1990). The link is Wadler's own page for his linear-logic papers.

Shows that if an array is used linearly, a pure functional program can update it in place, and introduces a 'let!' construct that lets the program read a linear value for a while without consuming it. This is the original statement of the exact goal behind beni's check: in-place edits of a value nobody else can still see, with a read-only borrow for inspection. Local PDF converted from the author's PostScript.

### Is there a use for linear logic?

Philip Wadler. PEPM 1991 (ACM SIGPLAN Notices 26(9)), 1991.  
`paper` · foundations, inference · **core reading**

- Link: <https://doi.org/10.1145/115866.115894>
- Open access: <https://homepages.inf.ed.ac.uk/wadler/papers/linearuse/linearuse.ps>
- Local copy: `pdf/1991-wadler-is-there-a-use-for-linear-logic.pdf`

Asks whether linear types can guarantee in-place update and finds that plain linearity is too weak: a linear value can come from a shared one, so 'used once from now on' does not mean 'only reference'. It is the earliest clear statement of the difference between linearity and uniqueness, which decides what kind of checker beni needs. Local PDF converted from the author's PostScript.

### Implementation of the typed call-by-value λ-calculus using a stack of regions

Mads Tofte, Jean-Pierre Talpin. POPL 1994, 1994.  
`paper` · foundations, inference · **core reading**

- Link: <https://doi.org/10.1145/174675.177855>
- Local copy: none
- Note: OpenAlex lists it as free to read at dl.acm.org/doi/pdf/10.1145/174675.177855, but ACM refuses scripted downloads (403), so no copy was saved.

Introduces region inference: the compiler, with no annotations, infers where each value lives and when its region can be freed, as an extension of Hindley-Milner inference with effects. It is the main precedent for inferring a memory property for a whole ML program after ordinary type inference, which is the shape of beni's planned checker.

### Alias burying: Unique variables without destructive reads

John Boyland. Software: Practice and Experience 31(6):533-553, 2001.  
`paper` · foundations, inference · **core reading**

- Link: <https://doi.org/10.1002/spe.370>
- Open access: <https://web.archive.org/web/20060505014254/http://www.cs.uwm.edu/~boyland/papers/unique-preprint.ps>
- Local copy: `pdf/2001-boyland-alias-burying.pdf`
- Note: Copy is the author's preprint, retrieved from the Internet Archive because the author's server did not respond; converted from PostScript.

Lets a unique variable be read without being destroyed, as long as every other alias created from it is dead ('buried') before the unique variable is used again, checked by a liveness-style analysis. This is very close to beni's rule — editing is fine once no one else can still observe the old version — and shows it can be checked by a static analysis rather than by types.

### A Retrospective on Region-Based Memory Management

Mads Tofte, Lars Birkedal, Martin Elsman, Niels Hallenberg. Higher-Order and Symbolic Computation 17(3):245-265, 2004.  
`paper` · foundations, inference, errors · **core reading**

- Link: <https://doi.org/10.1023/B:LISP.0000029446.78563.a4>
- Open access: <https://elsman.com/pdf/retro.pdf>
- Local copy: `pdf/2004-tofte-retrospective-on-region-based-memory-management.pdf`

Ten years on, the MLKit authors report what fully inferred regions were like to use: small source changes could silently change memory behaviour, and programmers needed tools to see what the inference decided. Direct evidence on the cost of making a whole-program memory property invisible, which beni must weigh when its uniqueness result is inferred.

### Substructural Type Systems (chapter 1 of Advanced Topics in Types and Programming Languages)

David Walker (in Benjamin C. Pierce, ed.). ATTAPL, MIT Press, ISBN 0-262-16228-8, 2005.  
`book` · foundations · **core reading**

- Link: <https://www.cis.upenn.edu/~bcpierce/attapl/>
- Local copy: none
- Note: Book chapter, not open access; no official free copy found.

The standard textbook chapter on linear, affine, relevant and ordered type systems, with a clean algorithmic linear checker that threads the set of unused variables through each expression. Its context-splitting algorithm is the simplest model of what a usage checker run after type inference has to compute.

### Practical Affine Types

Jesse A. Tov, Riccardo Pucella. POPL 2011, 2011.  
`paper` · foundations, inference · **core reading**

- Link: <https://doi.org/10.1145/1926385.1926436>
- Open access: <https://users.cs.northwestern.edu/~jesse/pubs/alms/tovpucella-alms.pdf>
- Local copy: `pdf/2011-tov-practical-affine-types.pdf`

Alms, an ML-like language with affine types where kinds record whether a type may be copied, and kind inference keeps annotations light while letting functions be polymorphic over 'copyable or not'. The closest prior attempt at making substructural types practical in an ML with inference; an extended version is at tovpucella-alms-long.pdf on the same page.

### Uniqueness and Reference Immutability for Safe Parallelism

Colin S. Gordon, Matthew J. Parkinson, Jared Parsons, Aleks Bromfield, Joe Duffy. OOPSLA 2012, 2012.  
`paper` · foundations, uniqueness-built, inference · **core reading**

- Link: <https://doi.org/10.1145/2384616.2384619>
- Open access: <https://www.cs.drexel.edu/~csg63//publications/oopsla12/oopsla12.pdf>
- Local copy: `pdf/2012-gordon-uniqueness-reference-immutability-safe-parallelism.pdf`

A C# extension used at Microsoft with isolated (unique), immutable, read-only and writable references, where an expression built only from isolated or immutable inputs can be 'recovered' to isolated without annotations. The recovery rule is a cheap, local way to conclude a freshly built value is unique, which beni could reuse; an extended tech report (MSR-TR-2012-79) is on the same site.

### Ownership Types: A Survey

Dave Clarke, Johan Östlund, Ilya Sergey, Tobias Wrigstad. Aliasing in Object-Oriented Programming, LNCS 7850, 2013.  
`paper` · foundations, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1007/978-3-642-36946-9_3>
- Open access: <https://ilyasergey.net/papers/ownership-survey.pdf>
- Local copy: `pdf/2013-clarke-ownership-types-a-survey.pdf`

A survey of ownership types, uniqueness, borrowing and their inference in object-oriented languages up to 2013, including a section on ownership inference and its precision problems. The best single map of the pre-Rust literature.

### Programming with Permissions in Mezzo

François Pottier, Jonathan Protzenko. ICFP 2013, 2013.  
`paper` · foundations, uniqueness-built, errors · **core reading**

- Link: <https://doi.org/10.1145/2500365.2500598>
- Open access: <http://gallium.inria.fr/~fpottier/publis/pottier-protzenko-mezzo.pdf>
- Local copy: `pdf/2013-pottier-programming-with-permissions-in-mezzo.pdf`

An ML-family language where the type checker tracks, at each program point, which permissions are held, including 'exclusive' (unique, mutable) versus 'duplicable' data, and infers much of this flow. The nearest design to a functional language checking uniqueness by flow; its experience with permission inference and error reporting is directly relevant. Project page: protz.github.io/mezzo.

### Linearity and Uniqueness: An Entente Cordiale

Daniel Marshall, Michael Vollmer, Dominic Orchard. ESOP 2022 (LNCS 13240), 2022.  
`paper` · foundations, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1007/978-3-030-99336-8_13>
- Open access: <https://kar.kent.ac.uk/98024/1/978-3-030-99336-8_13.pdf>
- Local copy: `pdf/2022-marshall-linearity-and-uniqueness-entente-cordiale.pdf`

Puts linearity (a promise about the future: this value will be used once) and uniqueness (a guarantee about the past: nobody else holds this value) side by side in one calculus, implemented in Granule, and shows they are dual. It is the clearest modern explanation of why beni's check, which is about the past, is a uniqueness property and not a linearity one.

### A taste of linear logic

Philip Wadler. MFCS 1993 (LNCS 711), invited talk, 1993.  
`paper` · foundations · **supporting**

- Link: <https://doi.org/10.1007/3-540-57182-5_12>
- Open access: <https://homepages.inf.ed.ac.uk/wadler/papers/lineartaste/lineartaste-revised.pdf>
- Local copy: `pdf/1993-wadler-a-taste-of-linear-logic.pdf`

A gentle tutorial on linear logic and the linear lambda calculus, written for programmers rather than logicians. The best first reading for the vocabulary (weakening, contraction, the '!' modality) that every later paper assumes.

### Region-Based Memory Management

Mads Tofte, Jean-Pierre Talpin. Information and Computation 132(2):109-176, 1997.  
`paper` · foundations, inference · **supporting**

- Link: <https://doi.org/10.1006/inco.1996.2613>
- Local copy: none
- Note: OpenAlex marks it free in Elsevier's open archive, but ScienceDirect returns 403 to scripted access, so no copy was saved.

The full journal account of region inference, with the soundness proof. Read with the 1994 paper for how effect information inferred alongside types decides when memory is dead.

### Flexible Alias Protection

James Noble, Jan Vitek, John Potter. ECOOP 1998 (LNCS 1445), 1998.  
`paper` · foundations · **supporting**

- Link: <https://doi.org/10.1007/BFb0054091>
- Open access: <https://access.archive-ouverte.unige.ch/access/metadata/f8485a54-4ac9-40de-ba81-d3aba70ccbe5/download>
- Local copy: `pdf/1998-noble-flexible-alias-protection.pdf`

Argues that aliasing is fine as long as changes are not observed through unexpected aliases, and proposes aliasing modes (rep, arg, free, val) that a checker enforces. Its 'free' mode for unaliased values and 'val' mode for value-like data map closely onto a pure language's distinction between unique and shared.

### Separation Logic: A Logic for Shared Mutable Data Structures

John C. Reynolds. LICS 2002, 2002.  
`paper` · foundations · **supporting**

- Link: <https://doi.org/10.1109/LICS.2002.1029817>
- Open access: <https://www.cs.cmu.edu/~jcr/seplogic.pdf>
- Local copy: `pdf/2002-reynolds-separation-logic.pdf`

The standard introduction to separation logic, where the separating conjunction says two parts of memory do not overlap, so a change to one cannot be seen through the other. Its 'frame rule' is the logical form of the guarantee beni wants: editing what you exclusively own cannot affect anyone else.

### Checking Interference with Fractional Permissions

John Boyland. SAS 2003 (LNCS 2694), 2003.  
`paper` · foundations · **supporting**

- Link: <https://doi.org/10.1007/3-540-44898-5_4>
- Open access: <https://web.archive.org/web/20100702182456/http://www.cs.uwm.edu/~boyland/papers/permissions.pdf>
- Local copy: `pdf/2003-boyland-checking-interference-fractional-permissions.pdf`
- Note: Copy is the author's preprint (marked 'to appear', revision 1.1), retrieved from the Internet Archive because the author's server did not respond.

Splits the permission to write a location into fractions: any fraction allows reading, only the whole allows writing, and fractions can be rejoined. This is the cleanest model of 'many readers or one writer', and of getting write access back once the readers are gone.

### Uniqueness logic

Dana G. Harrington. Theoretical Computer Science 354(1):24-41, 2006.  
`paper` · foundations, uniqueness-built · **supporting**

- Link: <https://doi.org/10.1016/j.tcs.2005.11.006>
- Local copy: none
- Note: OpenAlex marks it free in Elsevier's open archive (pii S0304397505008522), but ScienceDirect returns 403 to scripted access, so no copy was saved.

Builds a proof system for uniqueness, as Clean uses it, in the style of linear logic, and makes precise how 'unique' differs from 'linear'. Theory support for treating uniqueness as its own discipline.

### L3: A Linear Language with Locations **[unverified]**

Amal Ahmed, Matthew Fluet, Greg Morrisett. Fundamenta Informaticae 77(4):397-449 (journal version of TLCA 2005), 2007.  
`paper` · foundations · **supporting**

- Link: <https://www.ccs.neu.edu/home/amal/papers/linloc-fi07.pdf>
- Local copy: `pdf/2007-ahmed-l3-a-linear-language-with-locations.pdf`
- Unverified: Fundamenta Informaticae volume/pages from memory; DOI not checked.

Splits a pointer into a freely copyable name and a linear capability that grants access, which permits strong (type-changing) updates and safe aliasing of names. It shows how 'who may edit' can be tracked separately from 'who holds a reference', an alternative framing for beni's rule.

### Capabilities for Uniqueness and Borrowing

Philipp Haller, Martin Odersky. ECOOP 2010 (LNCS 6183), 2010.  
`paper` · foundations, uniqueness-built · **supporting**

- Link: <https://doi.org/10.1007/978-3-642-14107-2_17>
- Open access: <http://lampwww.epfl.ch/~phaller/doc/haller-odersky10-Capabilities_for_uniqueness_and_borrowing.pdf>
- Local copy: `pdf/2010-haller-capabilities-for-uniqueness-and-borrowing.pdf`

Uniqueness for Scala actors via capabilities, where a parameter can be borrowed without being consumed and unique objects can be passed between actors safely, with few annotations. Shows uniqueness and temporary borrowing working in a language with inference and closures.

### 15-816 Linear Logic, lecture notes (Spring 2012), lecture 11: Functional Computation

Frank Pfenning. Carnegie Mellon University course notes, 2012.  
`lecture` · foundations · **supporting**

- Link: <https://www.cs.cmu.edu/~fp/courses/15816-s12/>
- Open access: <https://www.cs.cmu.edu/~fp/courses/15816-s12/lectures/11-funcomp.pdf>
- Local copy: `pdf/2012-pfenning-linear-logic-lecture-11-linear-functional-computation.pdf`

An open course on linear logic whose notes run from inference rules to a linear lambda calculus and its evaluation (lecture 10 natural deduction, lecture 11 functional computation, lecture 18 resource management). The free substitute for the ATTAPL chapter; the saved lecture covers computing with linear terms.

### The Design and Formalization of Mezzo, a Permission-Based Programming Language

Thibaut Balabonski, François Pottier, Jonathan Protzenko. ACM TOPLAS 38(4), 2016.  
`paper` · foundations, uniqueness-built · **supporting**

- Link: <https://doi.org/10.1145/2837022>
- Open access: <http://gallium.inria.fr/~fpottier/publis/bpp-mezzo-journal.pdf>
- Local copy: `pdf/2016-balabonski-design-and-formalization-of-mezzo.pdf`

The full journal account of Mezzo, with its formal semantics, soundness proof and a frank discussion of what was hard to make usable. Use it with the ICFP paper for the design lessons.

### Syntax and Semantics of Quantitative Type Theory

Robert Atkey. LICS 2018, 2018.  
`paper` · foundations · **supporting**

- Link: <https://doi.org/10.1145/3209108.3209189>
- Open access: <https://bentnib.org/quantitative-type-theory.pdf>
- Local copy: `pdf/2018-atkey-syntax-and-semantics-of-quantitative-type-theory.pdf`

Fixes McBride's system so that each variable carries a usage count from a semiring (0, 1, many), with a sound semantics. This is the counting framework Idris 2 uses; for beni it shows how usage counts can be computed as a separate layer on top of an ordinary typing derivation.

### Quantitative program reasoning with graded modal types

Dominic Orchard, Vilem-Benjamin Liepelt, Harley Eades III. ICFP 2019 (PACMPL 3, ICFP), 2019.  
`paper` · foundations, inference · **supporting**

- Link: <https://doi.org/10.1145/3341714>
- Open access: <https://kar.kent.ac.uk/74450/1/paper.pdf>
- Local copy: `pdf/2019-orchard-quantitative-program-reasoning-graded-modal-types.pdf`

The Granule language: linear by default, with 'graded' modalities that say how often a value may be used, checked by generating constraints and handing them to an SMT solver. It shows usage tracking done as constraint solving next to type inference, and also what it costs in annotations and solver time.

### Idris 2: Quantitative Type Theory in Practice

Edwin Brady. ECOOP 2021 (LIPIcs 194), 2021.  
`paper` · foundations, uniqueness-built · **supporting**

- Link: <https://doi.org/10.4230/LIPIcs.ECOOP.2021.9>
- Open access: <https://drops.dagstuhl.de/storage/00lipics/lipics-vol194-ecoop2021/LIPIcs.ECOOP.2021.9/LIPIcs.ECOOP.2021.9.pdf>
- Local copy: `pdf/2021-brady-idris2-quantitative-type-theory-in-practice.pdf`

Reports how Idris 2 uses usage counts of 0, 1 and many in a real compiler, including linear resource protocols and erasure of compile-time-only arguments. Evidence of what counting usage costs programmers in practice; in Idris 2 the counts are written by the user, not inferred. Also on arXiv as 2104.00480.

### Programming with Regions in the MLKit (revised for version 4.7.16)

Mads Tofte, Niels Hallenberg, Lars Birkedal, Martin Elsman, Tommy Højfeld Olesen, Peter Sestoft. MLKit documentation, 2025.  
`docs` · foundations, inference, errors · **supporting**

- Link: <https://elsman.com/mlkit/>
- Open access: <https://elsman.com/mlkit/pdf/mlkit-4.7.16.pdf>
- Local copy: `pdf/2025-tofte-programming-with-regions-in-the-mlkit.pdf`

The MLKit's programmer guide to region inference, explaining how to read the inferred regions and rewrite code that leaks memory into long-lived regions. It shows how a compiler reports an inferred memory property back to users, a model for explaining beni's inferred ownership.

### Linear logic

Jean-Yves Girard. Theoretical Computer Science 50(1):1-101, 1987.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1016/0304-3975(87)90045-4>
- Open access: <https://girard.perso.math.cnrs.fr/linear.pdf>
- Local copy: `pdf/1987-girard-linear-logic.pdf`

The paper that introduced linear logic, where an assumption must be used exactly once unless it is marked with the 'of course' modality that allows copying and discarding. Every later linear, affine and uniqueness type system descends from it; the local copy is a scan (no text layer) hosted on Girard's own site.

### The linear abstract machine

Yves Lafont. Theoretical Computer Science 59(1-2):157-180, 1988.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1016/0304-3975(88)90100-4>
- Local copy: none
- Note: OpenAlex marks it free to read in Elsevier's open archive, but ScienceDirect refuses scripted access (403), so no copy was saved.

An early computational reading of linear logic as an abstract machine in which linear values need no garbage collection because they are consumed exactly once. Background for the idea that a single-use value can be reused or freed on the spot.

### Islands: aliasing protection in object-oriented languages

John Hogg. OOPSLA 1991, 1991.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/117954.117975>
- Local copy: none
- Note: No open-access copy found.

Early work on 'islands': groups of objects reachable from outside only through one bridge object, with unique references and read-only access enforcing the boundary. The first use of unique references plus read-only borrowing to stop outside mutation.

### Computational interpretations of linear logic

Samson Abramsky. Theoretical Computer Science 111(1-2):3-57, 1993.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1016/0304-3975(93)90181-R>
- Local copy: none
- Note: OpenAlex lists an Elsevier open-archive PDF (sciencedirect.com/science/article/pii/030439759390181R/pdf), but it returns 403 to scripted access, so it was not saved.

Gives linear logic a term language and shows how linear terms correspond to programs that manage resources explicitly, including a concurrent reading. Theory background only; nothing in it is directly an inference algorithm.

### Ownership types for flexible alias protection

David G. Clarke, John M. Potter, James Noble. OOPSLA 1998, 1998.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/286936.286947>
- Local copy: none
- Note: OpenAlex points to a KU Leuven Lirias record (green OA), but the handle redirects to a search page and no PDF was found.

The paper that introduced ownership types: each object has an owner, and references may not escape the owner's boundary. It is about encapsulation in object graphs rather than uniqueness, but it names the field of 'ownership' that later work builds on.

### Typed memory management in a calculus of capabilities

Karl Crary, David Walker, Greg Morrisett. POPL 1999, 1999.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/292540.292564>
- Open access: <https://nuprl-web.cs.cornell.edu/PRLSeminar/PRLSeminar99_00/Walker/capabilities.pdf>
- Local copy: `pdf/1999-crary-typed-memory-management-calculus-of-capabilities.pdf`

A typed low-level language in which the right to access a region is a capability that may be unique or shared, letting regions be freed explicitly and safely. Introduces the unique-versus-shared capability split that later permission systems reuse.

### Alias Types

Frederick Smith, David Walker, Greg Morrisett. ESOP 2000 (LNCS 1782), 2000.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1007/3-540-46425-5_24>
- Open access: <https://www.cs.princeton.edu/~dpw/papers/alias.pdf>
- Local copy: `pdf/2000-smith-alias-types.pdf`

Tracks aliasing in types by giving each memory location a name and a linear fact about what it holds, so several pointers to one location are allowed and known to agree. A low-level ancestor of L3 and of permission-based languages like Mezzo.

### Typed memory management via static capabilities

David Walker, Karl Crary, Greg Morrisett. ACM TOPLAS 22(4):701-771, 2000.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/363911.363923>
- Open access: <https://www.cs.princeton.edu/~dpw/papers/capabilities-toplas.pdf>
- Local copy: `pdf/2000-walker-typed-memory-management-via-static-capabilities.pdf`

The journal version of the calculus of capabilities, with full proofs and a translation from Tofte-Talpin region inference into it. Read only if the POPL version is not enough.

### Local Reasoning about Programs that Alter Data Structures

Peter O'Hearn, John Reynolds, Hongseok Yang. CSL 2001 (LNCS 2142), 2001.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1007/3-540-44802-0_1>
- Open access: <http://www0.cs.ucl.ac.uk/staff/p.ohearn/papers/localreasoning.pdf>
- Local copy: `pdf/2001-ohearn-local-reasoning-programs-alter-data-structures.pdf`

Introduces the frame rule and the idea of local reasoning: a command is specified only over the memory it touches. Foundational background for why exclusive ownership makes updates easy to reason about.

### On regions and linear types

David Walker, Kevin Watkins. ICFP 2001, 2001.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/507635.507658>
- Local copy: none
- Note: No open-access copy found on the authors' pages.

Combines regions with linear types so that regions themselves can be passed around and freed by linear capabilities, not only by lexical nesting. Background on joining the region and linearity traditions.

### Region-Based Memory Management in Cyclone

Dan Grossman, Greg Morrisett, Trevor Jim, Michael Hicks, Yanling Wang, James Cheney. PLDI 2002, 2002.  
`paper` · foundations, inference · **background**

- Link: <https://doi.org/10.1145/512529.512563>
- Open access: <https://www.cs.umd.edu/projects/cyclone/papers/cyclone-regions.pdf>
- Local copy: `pdf/2002-grossman-region-based-memory-management-cyclone.pdf`

Safe C with lexical regions, where defaults and local inference inside function bodies keep region annotations rare. A precursor of Rust's lifetimes and a data point on how much can be inferred locally versus declared at function boundaries.

### Permission Accounting in Separation Logic

Richard Bornat, Cristiano Calcagno, Peter O'Hearn, Matthew Parkinson. POPL 2005, 2005.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/1040305.1040327>
- Open access: <http://www0.cs.ucl.ac.uk/staff/p.ohearn/papers/permissions_paper.pdf>
- Local copy: `pdf/2005-bornat-permission-accounting-in-separation-logic.pdf`

Brings Boyland's fractional permissions and a counting variant into separation logic, so read-only sharing and its return to full ownership can be proved. Background for counting how many readers still hold a value before an edit is allowed.

### Linear Regions Are All You Need

Matthew Fluet, Greg Morrisett, Amal Ahmed. ESOP 2006 (LNCS 3924), 2006.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1007/11693024_2>
- Open access: <https://www.cs.rit.edu/~mtf/research/substruct-regions/ESOP06/esop06.pdf>
- Local copy: `pdf/2006-fluet-linear-regions-are-all-you-need.pdf`

Shows that Tofte-Talpin regions, Cyclone's dynamic regions and unique pointers can all be encoded in one small linear calculus over region capabilities. Useful as a map of how region systems and linear types relate.

### Resources, Concurrency and Local Reasoning

Peter W. O'Hearn. Theoretical Computer Science 375(1-3):271-307 (CONCUR 2004 invited paper), 2007.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1016/j.tcs.2006.12.035>
- Open access: <http://www0.cs.ucl.ac.uk/staff/p.ohearn/papers/concurrency.pdf>
- Local copy: `pdf/2007-ohearn-resources-concurrency-local-reasoning.pdf`

Concurrent separation logic: ownership of memory moves between threads and locks, and a program is safe if each piece of memory has one owner at a time. The idea of ownership transfer, not tied to any type system, that Rust and others later make static.

### I Got Plenty o' Nuttin'

Conor McBride. A List of Successes That Can Change the World (Wadler Festschrift), LNCS 9600, 2016.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1007/978-3-319-30936-1_12>
- Open access: <https://personal.cis.strath.ac.uk/conor.mcbride/PlentyO-CR.pdf>
- Local copy: `pdf/2016-mcbride-i-got-plenty-o-nuttin.pdf`

Proposes annotating each variable with how many times it is used, drawn from a semiring, so that 'used zero times' (types only) and 'used once' live in one system. The idea that became Quantitative Type Theory.

### A unified view of modalities in type systems

Andreas Abel, Jean-Philippe Bernardy. ICFP 2020 (PACMPL 4, ICFP), 2020.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/3408972>
- Open access: <https://www.cse.chalmers.se/~abela/icfp20.pdf>
- Local copy: `pdf/2020-abel-unified-view-of-modalities-in-type-systems.pdf`

One calculus, parameterised by a 'modality ring', that covers usage counting, irrelevance, sensitivity and similar annotations at once. Background for seeing an inferred uniqueness flag as one instance of a general graded-type framework; a long version is at icfp20-long.pdf on the same page.

## 2. Uniqueness typing as built

### SISAL 1.2: High-Performance Applicative Computing

David C. Cann, John T. Feo, Thomas M. DeBoni. LLNL preprint UCRL-JC-103980 (2nd IEEE Symposium on Parallel and Distributed Processing), 1990.  
`report` · uniqueness-built, inference · **core reading**

- Link: <https://www.osti.gov/servlets/purl/6569540>
- Local copy: `pdf/1990-cann-sisal-1.2-high-performance-applicative-computing.pdf`

Reports Sisal's compile-time copy elimination with run-time conditional copies, and counts how many copy sites the analysis removed and why the rest remained. The only measured failure rate for such an analysis on real programs (about 1% undecided).

### Uniqueness Type Inference

Erik Barendsen, Sjaak Smetsers. PLILP 1995 (LNCS 982), 1995.  
`paper` · uniqueness-built, inference · **core reading**

- Link: <https://doi.org/10.1007/BFb0026821>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1995/bare95-unitypeinference.ps.gz>
- Local copy: `pdf/1995-barendsen-uniqueness-type-inference.pdf`

Adds uniqueness polymorphism and an algorithm that infers the uniqueness variant of an ordinary Hindley-Milner type, the basis of Clean's checker. Its worked examples include the canonical false error (read then update the same array) and how Clean fixed it by changing the library API.

### Uniqueness Typing for Functional Languages with Graph Rewriting Semantics

Erik Barendsen, Sjaak Smetsers. Mathematical Structures in Computer Science 6(6), 1996.  
`paper` · uniqueness-built, inference, foundations · **core reading**

- Link: <https://doi.org/10.1017/S0960129500070109>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1996/bare96-uniclosed.pdf>
- Local copy: `pdf/1996-barendsen-uniqueness-typing-graph-rewriting-semantics.pdf`

The definitive theory of Clean's uniqueness typing, with let, case, higher-order functions, soundness and effective inference. It shows that types read as ordinary types once the uniqueness marks are ignored, and that inference never searches, so some recursive programs are simply rejected.

### Uniqueness Typing Redefined

Edsko de Vries, Rinus Plasmeijer, David M. Abrahamson. IFL 2006 (LNCS 4449), 2007.  
`paper` · uniqueness-built, inference, errors · **core reading**

- Link: <https://doi.org/10.1007/978-3-540-74130-5_11>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/2007/vrie2007-IFL06-UniquenessTypingRedefinedRev.pdf>
- Local copy: `pdf/2006-devries-uniqueness-typing-redefined.pdf`

Recasts uniqueness as a kind-level attribute so the rules become simpler and closer to ordinary type inference. It warns that an algorithm-W style inference gives unhelpful messages and points to constraint-based inference instead, which matters for beni's error quality.

### Uniqueness Typing Simplified

Edsko de Vries, Rinus Plasmeijer, David M. Abrahamson. IFL 2007 (LNCS 5083), 2008.  
`paper` · uniqueness-built, inference · **core reading**

- Link: <https://doi.org/10.1007/978-3-540-85373-2_12>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/2008/vrie08-IFL07-UniquenessTypingSimplified.pdf>
- Local copy: `pdf/2007-devries-uniqueness-typing-simplified.pdf`

The most direct recipe for uniqueness inference on top of Hindley-Milner, with no subtyping and careful library types. It names partial application and recursion as the hard cases and gives the examples it still rejects.

### Clean Version 2.2 Language Report, Chapter 9: Uniqueness Typing

Rinus Plasmeijer, Marko van Eekelen, John van Groningen. Radboud University Nijmegen language report, 2011.  
`spec` · uniqueness-built, errors · **core reading**

- Link: <https://ftp.cs.ru.nl/Clean/html_report/CleanRep.2.2_11.htm>
- Open access: <https://clean.cs.ru.nl/download/doc/CleanLangRep.2.2.pdf>
- Local copy: `text/2011-clean-2.2-report-ch9-uniqueness-typing.txt` (saved 2026-10-10)

The user-facing rules of Clean's uniqueness typing: propagation into containers, unique partial applications, observing versus sharing references, and attribute variables. It is the best description of what a programmer actually has to understand, and the full report PDF is saved as pdf/2011-plasmeijer-clean-2.2-language-report.pdf.

### Design and Implementation of the Futhark Programming Language

Troels Henriksen. PhD thesis, DIKU, University of Copenhagen, 2017.  
`thesis` · uniqueness-built · **core reading**

- Link: <https://futhark-lang.org/publications/troels-henriksen-phd-thesis.pdf>
- Local copy: `pdf/2017-henriksen-design-and-implementation-of-futhark-thesis.pdf`

Explains the uniqueness check as a simple conservative intra-procedural alias analysis that reports errors, and measures what in-place updates are worth (8.3x on k-means). It also notes the check is tractable because Futhark has no pointer structures, which beni's lists in records do not escape.

### Futhark: Purely Functional GPU-Programming with Nested Parallelism and In-Place Array Updates

Troels Henriksen, Niels G. W. Serup, Martin Elsman, Fritz Henglein, Cosmin E. Oancea. PLDI 2017, 2017.  
`paper` · uniqueness-built · **core reading**

- Link: <https://doi.org/10.1145/3062341.3062354>
- Open access: <https://futhark-lang.org/publications/pldi17.pdf>
- Local copy: `pdf/2017-henriksen-futhark-purely-functional-gpu-programming.pdf`

Describes Futhark's uniqueness types for arrays: consumption marked only on function parameters and results, checked inside each function. It is the closest production design to what beni is considering, in a pure strict language.

### Uniqueness Types and In-Place Updates

Troels Henriksen. Futhark blog, 2022-06-13, 2022.  
`blog` · uniqueness-built, errors · **core reading**

- Link: <https://futhark-lang.org/blog/2022-06-13-uniqueness-types.html>
- Local copy: `text/2022-futhark-uniqueness-types-and-in-place-updates.txt` (saved 2026-10-10)

A plain-language account of Futhark's rules: errors are always fixable with a copy, order is purely syntactic, closures may not consume free variables. It reports that real uses are simple and local, and argues for simple rules over clever ones.

### Do Not Let Your Type System Reason About Aliasing in Your Programming Language

Troels Henriksen. Futhark blog, 2026-09-22, 2026.  
`blog` · uniqueness-built, recent, errors · **core reading**

- Link: <https://futhark-lang.org/blog/2026-09-22-aliasing.html>
- Local copy: `text/2026-futhark-do-not-reason-about-aliasing.txt` (saved 2026-10-10)

The designer of the closest production system warns that a soundness fix made common polymorphic code (id, pipelines, composition) fail and pushed freshness annotations into the prelude. It proposes using parametricity to infer how results alias arguments, the most relevant open problem for beni.

### Futhark Compiler Error Index (section 8.1, Consumption errors)

Futhark developers. Futhark documentation (latest), 2026.  
`docs` · uniqueness-built, errors · **core reading**

- Link: <https://futhark.readthedocs.io/en/latest/error-index.html>
- Local copy: `text/2026-futhark-error-index.txt` (saved 2026-10-10)

One page per error, each with a minimal example and a fix, most of them about aliasing and consumption ('Using x, but this was consumed at y'). It is the best existing model for how beni could word and document ownership errors.

### Copy Elimination in Functional Languages

K. Gopinath, John L. Hennessy. POPL 1989, 1989.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/75277.75304>
- Local copy: none

An abstract-interpretation analysis that finds where aggregates can be built in place instead of copied, the theory behind Sisal's optimiser. It treats copies as a target-location problem rather than a type discipline.

### Conventional and Uniqueness Typing in Graph Rewrite Systems

Erik Barendsen, Sjaak Smetsers. FSTTCS 1993 (LNCS 761), 1993.  
`paper` · uniqueness-built, foundations · **supporting**

- Link: <https://doi.org/10.1007/3-540-57529-4_42>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1993/bare93-typinggrs.ps.gz>
- Local copy: `pdf/1993-barendsen-conventional-and-uniqueness-typing-grs.pdf`

The first formal uniqueness type system behind Clean, proving that types are preserved under graph rewriting. It already notes that curried functions need a special restriction, the first sign of the higher-order trouble every later system meets.

### Strong Modes Can Change the World!

Fergus Henderson. Honours report, Department of Computer Science, University of Melbourne, 1993.  
`report` · uniqueness-built, inference · **supporting**

- Link: <https://mercurylang.org/documentation/papers/fjh_hons.ps.gz>
- Local copy: `pdf/1993-henderson-strong-modes-can-change-the-world.pdf`

The report that introduced Mercury's unique modes for destructive update and I/O in a logic language. It shows uniqueness expressed as data-flow modes checked by the compiler rather than as type attributes.

### Guaranteeing Safe Destructive Updates through a Type System with Uniqueness Information for Graphs

Sjaak Smetsers, Erik Barendsen, Marko van Eekelen, Rinus Plasmeijer. Graph Transformations in Computer Science, Dagstuhl 1993 (LNCS 776), 1994.  
`paper` · uniqueness-built · **supporting**

- Link: <https://doi.org/10.1007/3-540-57787-4_23>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1994/smes94-guaranteeing.pdf>
- Local copy: `pdf/1994-smetsers-guaranteeing-safe-destructive-updates.pdf`

The practical Clean paper: it builds evaluation order into the type rules by letting arguments evaluated first only observe a value that a later argument updates. It reports that real programs, from a text editor to a database, were written under the system.

### The Ins and Outs of Clean I/O

Peter Achten, Rinus Plasmeijer. Journal of Functional Programming 5(1), 1995.  
`paper` · uniqueness-built · **supporting**

- Link: <https://doi.org/10.1017/s0956796800001258>
- Open access: <https://www.cambridge.org/core/services/aop-cambridge-core/content/view/2EFAEBBE3A19EA03A8D6D75A5348E194/S0956796800001258a.pdf/div-class-title-the-ins-and-outs-of-clean-i-o-div.pdf>
- Local copy: `pdf/1995-achten-ins-and-outs-of-clean-io.pdf`

Shows uniqueness typing used at scale for file and GUI I/O in Clean, threading a unique world through whole programs. It is the main evidence of how the discipline feels in large real code, including where it gets heavy.

### Practical Aspects for a Working Compile Time Garbage Collection System for Mercury

Nancy Mazur, Peter Ross, Gerda Janssens, Maurice Bruynooghe. ICLP 2001 (LNCS 2237), 2001.  
`paper` · inference, uniqueness-built · **supporting**

- Link: <https://doi.org/10.1007/3-540-45635-X_15>
- Open access: <https://mercurylang.org/documentation/papers/iclp2001_ctgc.ps.gz>
- Local copy: `pdf/2001-mazur-practical-aspects-compile-time-gc-mercury.pdf`

Inferred structure sharing and liveness analysis in the Mercury compiler, used to reuse dead cells without any annotation. It is the silent-optimisation counterpart of an error-reporting uniqueness check, with the same analysis inside.

### Constraint-Based Mode Analysis of Mercury

David Overton, Zoltan Somogyi, Peter J. Stuckey. PPDP 2002, 2002.  
`paper` · inference, uniqueness-built · **supporting**

- Link: <https://doi.org/10.1145/571157.571169>
- Open access: <https://mercurylang.org/documentation/papers/ppdp02_mode.pdf>
- Local copy: `pdf/2002-overton-constraint-based-mode-analysis-of-mercury.pdf`

Turns mode inference, including unique modes, into Boolean constraints solved in one go rather than by ad hoc search. A model for running an ownership analysis as a constraint problem after type checking.

### Precise and Expressive Mode Systems for Typed Logic Programming Languages

David Overton. PhD thesis, University of Melbourne, 2003.  
`thesis` · uniqueness-built, inference · **supporting**

- Link: <https://mercurylang.org/documentation/papers/dmo-thesis.ps.gz>
- Local copy: `pdf/2003-overton-precise-and-expressive-mode-systems-thesis.pdf`

Extends Mercury's modes with precise aliasing and uniqueness tracking and infers them with a constraint solver. It is the most complete treatment of inferred uniqueness as a mode analysis.

### Implicit Memory Management for SAC

Clemens Grelck, Kai Trojahner. IFL 2004 draft proceedings, University of Kiel, 2004.  
`paper` · inference, uniqueness-built · **supporting**

- Link: <https://research.uni-luebeck.de/en/publications/implicit-memory-management-for-sac/>
- Open access: <https://www.sac-home.org/_media/publications:pdf:greltrojifl04.pdf>
- Local copy: `pdf/2004-grelck-implicit-memory-management-for-sac.pdf`

How SaC's compiler inserts reference counting and reuses dead arrays for in-place updates, with optimisations that remove most of the counting. Shows what the fully automatic, error-free route costs and gains. The local PDF text layer is garbled; render it to read.

### SAC: A Functional Array Language for Efficient Multi-threaded Execution

Clemens Grelck, Sven-Bodo Scholz. International Journal of Parallel Programming 34(4), 2006.  
`paper` · uniqueness-built · **supporting**

- Link: <https://doi.org/10.1007/s10766-006-0018-x>
- Open access: <https://www.sac-home.org/_media/publications:pdf:safalfeme.pdf>
- Local copy: `pdf/2006-grelck-sac-functional-array-language-multithreaded.pdf`

The main overview of SaC, a pure array language whose compiler infers reference counts and updates arrays in place when the count is one. It is the silent run-time alternative to a compile-time ownership error.

### Equality Based Uniqueness Typing

Edsko de Vries, Rinus Plasmeijer, David M. Abrahamson. TFP 2007 (draft proceedings), 2007.  
`paper` · uniqueness-built, inference, errors · **supporting**

- Link: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/2007/vrie2007-TFP07-EqualityBasedUniquenessTyping.pdf>
- Local copy: `pdf/2007-devries-equality-based-uniqueness-typing.pdf`

Drops subtyping on uniqueness attributes and uses plain unification, so the system fits a standard Hindley-Milner solver. It also shows the kind of confusing message a simplified system produces, a useful warning for wording.

### Making Uniqueness Typing Less Unique

Edsko de Vries. PhD thesis, Trinity College Dublin, 2009.  
`thesis` · uniqueness-built, inference · **supporting**

- Link: <https://hdl.handle.net/2262/90081>
- Local copy: none
- Note: Trinity College Dublin's repository refuses scripted downloads (403), so there is no local copy; open it in a browser.

De Vries's thesis collecting the redefined, equality-based and simplified systems with full proofs. Its content is covered by the three papers above, which are saved.

### Anatomy of a Type Checker Bug

Troels Henriksen. Futhark blog, 2021-05-11, 2021.  
`blog` · uniqueness-built, errors · **supporting**

- Link: <https://futhark-lang.org/blog/2021-05-11-anatomy-of-a-type-checker-bug.html>
- Local copy: `text/2021-futhark-anatomy-of-a-type-checker-bug.txt` (saved 2026-10-10)

A soundness bug where alias tracking keyed on variable names missed unnamed intermediate results, fixed by naming every application. It shows how such a checker goes wrong and why explaining long alias chains to users is hard.

### Futhark Language Reference: In-place Updates, Alias Analysis, In-place Updates and Higher-Order Functions

Futhark developers. Futhark documentation (latest), 2026.  
`docs` · uniqueness-built · **supporting**

- Link: <https://futhark.readthedocs.io/en/latest/language-reference.html#in-place-updates>
- Local copy: none

The normative statement of Futhark's consumption and aliasing rules, including the special rules for higher-order functions. Not saved because the page is the whole language reference.

### Rewriting the Futhark Type Checker

Troels Henriksen. Futhark blog, 2026-07-21, 2026.  
`blog` · uniqueness-built, recent · **supporting**

- Link: <https://futhark-lang.org/blog/2026-07-21-rewriting-the-type-checker.html>
- Local copy: `text/2026-futhark-rewriting-the-type-checker.txt` (saved 2026-10-10)

Futhark moved alias checking out of type inference into its own pass over a fully typed program. This is the same architecture beni would use: a uniqueness pass after Hindley-Milner, not inside it.

### The Mercury Language Reference Manual, Chapter 6: Unique Modes

Fergus Henderson, Thomas Conway, Zoltan Somogyi, David Jeffery, Peter Schachte, Simon Taylor, Chris Speirs, Tyson Dowd, Ralph Becket, Mark Brown, Peter Wang. Mercury documentation (latest), 2026.  
`docs` · uniqueness-built · **supporting**

- Link: <https://mercurylang.org/information/doc-latest/mercury_reference_manual/Unique-modes.html>
- Local copy: `text/2026-mercury-reference-manual-unique-modes.txt` (saved 2026-10-10)

Mercury's di/uo/ui modes, which mark a value as unique and then dead, used for destructive update and declarative I/O. The manual still calls the feature incompletely implemented, a useful data point on how hard full uniqueness is in practice.

### Compilation Techniques for High Performance Applicative Computation **[unverified]**

David C. Cann. PhD thesis, Colorado State University (tech. report CS-89-108), 1989.  
`thesis` · inference, uniqueness-built · **background**

- Link: none found online
- Local copy: none
- Unverified: no online copy or DOI found (OSTI was erroring and web search was exhausted); year and report number from citations only

Cann's thesis on the Sisal optimiser, including update-in-place and the ordering edges that put reads before writes. The source for the techniques the 1990 report measures.

### A Report on the Sisal Language Project

John T. Feo, David C. Cann, Rodney R. Oldehoeft. Journal of Parallel and Distributed Computing 10(4), 1990.  
`paper` · uniqueness-built · **background**

- Link: <https://doi.org/10.1016/0743-7315(90)90035-n>
- Local copy: none

Overview of the Sisal project, its compiler and its optimisations, including the update-in-place analysis. Background for how the copy-elimination numbers were obtained.

### Retire Fortran? A Debate Rekindled

David Cann. Communications of the ACM 35(8), 1992.  
`paper` · uniqueness-built · **background**

- Link: <https://doi.org/10.1145/135226.135231>
- Local copy: none

Argues that Sisal matches Fortran speed on supercomputers, largely thanks to update-in-place and copy elimination. Evidence that a pure language can get imperative performance from inferred in-place updates.

### Compile-Time Copy Elimination

Peter Schnorf, Mahadevan Ganapathi, John L. Hennessy. Software: Practice and Experience 23(11), 1993.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1002/spe.4380231102>
- Local copy: none

Implements and measures copy elimination for a single-assignment language (Sisal) in a real compiler. Practical evidence on how often the static analysis succeeds.

### Functional Programming and Parallel Graph Rewriting, Chapter 8: Clean (section 8.5 Unique types and destructive updates)

Rinus Plasmeijer, Marko van Eekelen. Addison-Wesley book (authors' open chapter files), 1993.  
`book` · uniqueness-built, foundations · **background**

- Link: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1993/plaseek93/>
- Open access: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1993/plaseek93/Ch08.Clean.ps>
- Local copy: none

The textbook chapter introducing Clean, whose section 8.5 explains unique types and destructive updates for readers rather than theorists. Every chapter of the book is on the Nijmegen server as PostScript; this one failed to convert to PDF because of a missing embedded image.

### A Derivation System for Uniqueness Typing **[unverified]**

Erik Barendsen, Sjaak Smetsers. University of Nijmegen preprint, 1995.  
`report` · uniqueness-built · **background**

- Link: <https://ftp.cs.ru.nl/CSI/SoftwEng.FunctLang/papers/1995/bare95-unitypederiv.pdf>
- Local copy: `pdf/1995-barendsen-derivation-system-for-uniqueness-typing.pdf`
- Unverified: published venue not confirmed (possibly SEGRAGRA'95 workshop); only the Nijmegen file and its abstract were seen

A first-order, natural-deduction presentation of conventional and polymorphic uniqueness typing for graph expressions. It is the cleanest short statement of the rules before the full MSCS paper.

### Classes and Objects as Basis for I/O in SAC

Clemens Grelck, Sven-Bodo Scholz. IFL 1995, Bastad (Chalmers proceedings), 1995.  
`paper` · uniqueness-built · **background**

- Link: <https://www.sac-home.org/_media/publications:pdf:sac-classes-objects-bastad-95.pdf>
- Local copy: `pdf/1995-grelck-classes-and-objects-as-basis-for-io-in-sac.pdf`

SaC's I/O uses uniqueness typing, but hides the attribute behind special 'class' modules instead of Clean's explicit marks. An early example of uniqueness made invisible to the programmer by tying it to particular types.

### Compile-Time Garbage Collection for the Declarative Language Mercury

Nancy Mazur. PhD thesis, Katholieke Universiteit Leuven, 2004.  
`thesis` · inference · **background**

- Link: <https://mercurylang.org/documentation/papers/CW2004_03_mazur.pdf>
- Local copy: `pdf/2004-mazur-compile-time-garbage-collection-for-mercury-thesis.pdf`

The full design and measurements of Mercury's sharing, liveness and reuse analyses, modular across compilation units. Useful for how a whole-program sharing analysis is organised per module.

### Clean Language Report, Version 3.0 (chapter 9, Uniqueness Typing) **[unverified]**

Rinus Plasmeijer, Marko van Eekelen, John van Groningen and the Clean contributors. Cloogle documentation browser, 2022.  
`spec` · uniqueness-built · **background**

- Link: <https://cloogle.org/doc/#_9>
- Open access: <https://cloogle.org/doc/>
- Local copy: none
- Unverified: copyright line reads 2016-2022; the exact release year of the 3.0 text was not confirmed

The current Clean 3.0 report with the same uniqueness chapter updated for the modern compiler. Useful to see which rules survived thirty years of use.

## 3. Inference algorithms

### How to Make Destructive Updates Less Destructive

Martin Odersky. POPL 1991, 1991.  
`paper` · inference, foundations · **core reading**

- Link: <https://doi.org/10.1145/99583.99590>
- Local copy: none

A static criterion that checks any side effect of a destructive update stays invisible, with read-only 'observer' uses allowed alongside. This is the beni owner's rule stated as a check rather than an optimisation.

### Order-of-Evaluation Analysis for Destructive Updates in Strict Functional Languages with Flat Aggregates

A. V. S. Sastry, William Clinger, Zena Ariola. FPCA 1993, 1993.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1145/165180.165222>
- Local copy: none

For strict languages, chooses an evaluation order that puts reads before writes so more updates become destructive, in near-linear time. Directly relevant because beni is strict, though beni can only use the order the source already fixes.

### Points-to Analysis in Almost Linear Time

Bjarne Steensgaard. POPL 1996, 1996.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1145/237721.237727>
- Open access: <https://www.cs.cornell.edu/courses/cs711/2005fa/papers/steensgaard-popl96.pdf>
- Local copy: `pdf/1996-steensgaard-points-to-analysis-almost-linear-time.pdf`

Unification-based points-to analysis in almost linear time, merging any two values that might meet. It is exactly the precision trade-off of piggy-backing sharing on a Hindley-Milner unifier, and its cost profile fits a fast compiler.

### Once Upon a Polymorphic Type

Keith Wansbrough, Simon Peyton Jones. POPL 1999, 1999.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1145/292540.292545>
- Open access: <https://www.lochan.org/keith/publications/popl99-usage.ps.gz>
- Local copy: `pdf/1999-wansbrough-once-upon-a-polymorphic-type.pdf`

Usage inference made to work with polymorphism and higher-order code in GHC, with usage polymorphism and constraint solving. Directly addresses the polymorphic-pipeline weakness Futhark hit.

### Set Constraints for Destructive Array Update Optimization

Mitchell Wand, William D. Clinger. Journal of Functional Programming 11(3) (first at ICCL 1998), 2001.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1017/S0956796801003938>
- Open access: <https://www.cambridge.org/core/services/aop-cambridge-core/content/view/7FB3D17C44EC7B1C98EE99CD6825A303/S0956796801003938a.pdf/div-class-title-set-constraints-for-destructive-array-update-optimization-div.pdf>
- Local copy: `pdf/2001-wand-set-constraints-destructive-array-update.pdf`

Recasts update-in-place analysis as set constraints solved in polynomial time, replacing exponential earlier methods. It still handles only flat arrays and first-order code, the limits beni would have to lift.

### Another Type System for In-Place Update

David Aspinall, Martin Hofmann. ESOP 2002 (LNCS 2305), 2002.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1007/3-540-45927-8_4>
- Open access: <https://homepages.inf.ed.ac.uk/da/papers/readonly/readonly.pdf>
- Local copy: `pdf/2002-aspinall-another-type-system-for-in-place-update.pdf`

Replaces strict linearity with three usage aspects per argument: destroyed, read and shared with the result, read and not shared. That is the read-only distinction an inferred beni rule needs to avoid false errors on plain reads.

### A Type System with Usage Aspects

David Aspinall, Martin Hofmann, Michal Konečný. Journal of Functional Programming 18(2), 2008.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1017/S0956796807006399>
- Open access: <https://homepages.inf.ed.ac.uk/da/papers/readonly-long/usageaspects.pdf>
- Local copy: `pdf/2008-aspinall-type-system-with-usage-aspects.pdf`

The journal version, proving that first-order programs have a best usage typing found by a fixed-point search from the most optimistic guess. It means the precise answer is computable without annotations, at least for first-order code.

### Counting Immutable Beans: Reference Counting Optimized for Purely Functional Programming

Sebastian Ullrich, Leonardo de Moura. IFL 2019, 2019.  
`paper` · inference, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1145/3412932.3412935>
- Open access: <https://arxiv.org/pdf/1908.05647>
- Local copy: `pdf/2019-ullrich-counting-immutable-beans.pdf`

Lean 4's runtime design: reference counting with a run-time uniqueness test so a pure update mutates in place when the count is one, plus a borrow inference that decides which parameters need no count. It is the inferred-borrowing baseline every later system (Koka, Roc, Morphic) measures against, and shows how much can be inferred with no user annotations.

### Perceus: Garbage Free Reference Counting with Reuse

Alex Reinking, Ningning Xie, Leonardo de Moura, Daan Leijen. PLDI 2021 (extended version MSR-TR-2020-42), 2021.  
`paper` · inference, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1145/3453483.3454032>
- Open access: <https://www.microsoft.com/en-us/research/wp-content/uploads/2020/11/perceus-tr-v4.pdf>
- Local copy: `pdf/2021-reinking-perceus-garbage-free-reference-counting-tr.pdf`

Koka's precise reference counting with reuse analysis: the compiler pairs a matched cell that dies with a new allocation of the same size, so pure code updates in place when the value is unique at run time. It defines the "functional but in-place" style and the ownership calculus (owned vs borrowed environments) any inferred checker would build on.

### Reachability Types: Tracking Aliasing and Separation in Higher-Order Functional Programs

Yuyan Bao, Guannan Wei, Oliver Bračevac, Yuxuan Jiang, Qiyang He, Tiark Rompf. OOPSLA 2021, 2021.  
`paper` · inference, foundations · **core reading**

- Link: <https://doi.org/10.1145/3485516>
- Open access: <https://www.cs.purdue.edu/homes/rompf/papers/bao-oopsla21.pdf>
- Local copy: `pdf/2021-bao-reachability-types.pdf`

Types carry the set of variables a value may reach, so sharing is allowed and tracked and separation is demanded only where needed. It is the type-system form of the owner's rule ("you may share; you may not update what is shared"), for higher-order functional code.

### Aliasing Limits on Translating C to Safe Rust

Mehmet Emre, Peter Boyland, Aesha Parekh, Ryan Schroeder, Kyle Dewey, Ben Hardekopf. OOPSLA 2023 (PACMPL 7, OOPSLA1), 2023.  
`paper` · inference, rust · **core reading**

- Link: <https://doi.org/10.1145/3586046>
- Open access: <https://www.cs.usfca.edu/~memre/oopsla23-aliasing-limits.pdf>
- Local copy: `pdf/2023-emre-aliasing-limits-translating-c-to-safe-rust.pdf`

Measures how far automatic ownership and borrow inference can go when translating real C programs to safe Rust, and where aliasing patterns defeat it. Empirical evidence on the precision ceiling of inferred ownership on real code.

### FP²: Fully in-Place Functional Programming

Anton Lorenzen, Daan Leijen, Wouter Swierstra. ICFP 2023 (TR MSR-TR-2023-19), 2023.  
`paper` · inference, uniqueness-built, errors · **core reading**

- Link: <https://doi.org/10.1145/3607840>
- Open access: <https://www.microsoft.com/en-us/research/wp-content/uploads/2023/05/fip-tr-v2.pdf>
- Local copy: `pdf/2023-lorenzen-fp2-fully-in-place-functional-programming-tr.pdf`

Defines a linear calculus and a checker (Koka's `fip` keyword) that rejects a function at compile time unless it provably runs without allocation, using borrowed vs owned parameters. It is a deployed compile-time error for "this will not run in place", annotated per function rather than inferred, and so a direct model for the error side of the owner's proposal.

### Oxidizing OCaml: Rust-Style Ownership

Max Slater (Jane Street). Jane Street Tech Blog, 2023-06-21, 2023.  
`blog` · uniqueness-built, inference, errors · **core reading**

- Link: <https://blog.janestreet.com/oxidizing-ocaml-ownership/>
- Local copy: `text/2023-janestreet-oxidizing-ocaml-ownership.txt` (saved 2026-10-10)

Introduces unique and once modes in OCaml with examples of the errors users see when a unique value is used twice. A practitioner-level description of an inferred uniqueness checker bolted onto an ML type checker.

### Static Uniqueness Analysis for the Lean 4 Theorem Prover

Marcel Huisinga. Master's thesis, Karlsruhe Institute of Technology, 2023.  
`thesis` · inference, errors · **core reading**

- Link: <https://pp.ipd.kit.edu/uploads/publikationen/huisinga23masterarbeit.pdf>
- Local copy: `pdf/2023-huisinga-static-uniqueness-analysis-lean4-thesis.pdf`
- Note: author first name taken from the thesis PDF metadata as cited in research 69; not re-read

Builds a static analysis that warns Lean users when an update they expect to be in place will copy because the value is shared. It is the closest existing attempt at exactly the owner's proposal: inferred uniqueness, reported to the user, layered on a pure language that already has reference counting.

### Oxidizing OCaml with Modal Memory Management

Anton Lorenzen, Leo White, Stephen Dolan, Richard A. Eisenberg, Sam Lindley. ICFP 2024, 2024.  
`paper` · inference, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1145/3674642>
- Open access: <https://antonlorenzen.de/papers/oxidizing-ocaml-modal-memory-management.pdf>
- Local copy: `pdf/2024-lorenzen-oxidizing-ocaml-modal-memory-management.pdf`

Adds uniqueness, linearity and locality to OCaml as modes inferred alongside Hindley-Milner types, with annotations needed mostly at interfaces, and reports annotation counts from Jane Street's codebase. It is the closest deployed analogue of a uniqueness checker run with an HM checker; the homepages.inf.ed.ac.uk/slindley/papers/mode-inference.pdf link cited in research 68/69 is byte-identical to this PDF.

### Polymorphic Reachability Types: Tracking Freshness, Aliasing, and Separation in Higher-Order Generic Programs

Guannan Wei, Oliver Bračevac, Songlin Jia, Yuyan Bao, Tiark Rompf. POPL 2024, 2024.  
`paper` · inference · **core reading**

- Link: <https://doi.org/10.1145/3632856>
- Open access: <https://arxiv.org/pdf/2307.13844>
- Local copy: `pdf/2024-wei-polymorphic-reachability-types.pdf`

Shows naive polymorphic extensions of reachability are unsound and fixes it by tracking one-step reachability, closed transitively only when needed. This is the polymorphism problem Futhark hit, solved in theory, and beni's List is polymorphic.

### Lean Language Reference: Reference Counting

Lean FRO. Lean reference manual (latest), 2025.  
`docs` · uniqueness-built, inference · **core reading**

- Link: <https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/>
- Local copy: `text/lean-reference-manual-reference-counting.txt` (saved 2026-10-10)
- Note: page is undated (living document); year is when it was current

The official description of how Lean counts references, when an Array or String update happens in place, and how to observe accidental sharing. It is the user-facing contract of a system where in-place update is an optimisation and never an error, the opposite design point from a checker.

### OxCaml compiler: typing/uniqueness_analysis.ml

Jane Street OxCaml team. oxcaml/oxcaml GitHub, 2025.  
`code` · inference, errors · **core reading**

- Link: <https://github.com/oxcaml/oxcaml/blob/main/typing/uniqueness_analysis.ml>
- Local copy: none
- Note: year is the last-checked date

The production pass that checks uniqueness after type checking, tracking usages through paths and branches and emitting the user errors. The most directly reusable implementation reference for a post-HM uniqueness pass.

### OxCaml documentation: Uniqueness and Linearity - Introduction

Jane Street OxCaml team. oxcaml.org, 2025.  
`docs` · uniqueness-built, inference, errors · **core reading**

- Link: <https://oxcaml.org/documentation/uniqueness/intro/>
- Local copy: `text/oxcaml-docs-uniqueness-intro.txt` (saved 2026-10-10)
- Note: living document; year approximate

The user manual for OxCaml's unique/aliased and once/many modes, including what is inferred and what must be written. The current, authoritative description of the deployed design.

### Escape with Your Self: Sound and Expressive Bidirectional Typing with Avoidance for Reachability Types

Songlin Jia, Guannan Wei, Siyuan He, Yuyan Bao, Tiark Rompf. PLDI 2026 (PACMPL 10, PLDI), 2026.  
`paper` · inference, recent · **core reading**

- Link: <https://doi.org/10.1145/3808335>
- Open access: <https://arxiv.org/pdf/2404.08217>
- Local copy: `pdf/2026-jia-escape-with-your-self-reachability-types.pdf`

Gives a decidable, sound bidirectional checking algorithm for reachability types that infers qualifiers by lightweight unification, mechanised in Lean. It is the answer to "can reachability be checked algorithmically with little annotation", the paper research 69 called the decidable algorithm.

### Fully-Automatic Type Inference for Borrows with Lifetimes **[unverified]**

William Brandon, Benjamin Driscoll, Frank Dai, Jonathan Ragan-Kelley, Mae Milano, Alex Aiken. OOPSLA 2026 (PACMPL 10, OOPSLA1), 2026.  
`paper` · inference, recent · **core reading**

- Link: <https://doi.org/10.1145/3798221>
- Open access: <https://theory.stanford.edu/~aiken/publications/papers/oopsla26a.pdf>
- Local copy: `pdf/2026-brandon-fully-automatic-type-inference-borrows-lifetimes.pdf`
- Unverified: author order differs: ACM/SPLASH list Brandon first, Aiken's publication page lists Driscoll first

A pure functional language whose compiler infers Rust-style borrows with lifetimes with no annotations, inserting reference counting only where typing fails; it removes 75-100% of count increments. It is the newest whole-program, annotation-free ownership inference for a strict pure language, the closest technical match to the owner's setting.

### Mode Crossing

Benjamin Peters, Jules Jacobs, Diana Kalinichenko, Liam Stevenson, Aspen Smith, Derek Dreyer, Richard A. Eisenberg. ICFP 2026 (PACMPL 10, ICFP), 2026.  
`paper` · inference, recent · **core reading**

- Link: <https://doi.org/10.1145/3828681>
- Open access: <https://iris-project.org/pdfs/2026-icfp-modecrossing.pdf>
- Local copy: `pdf/2026-peters-mode-crossing.pdf`

Explains how types like int ignore modes so most code never mentions uniqueness, and measures annotations in Jane Street's deployed code. Directly relevant to keeping an inferred checker silent on immutable scalars and other values where ownership cannot matter.

### The Aggregate Update Problem in Functional Programming Systems

Paul Hudak, Adrienne Bloss. POPL 1985, 1985.  
`paper` · inference, foundations · **supporting**

- Link: <https://doi.org/10.1145/318593.318660>
- Local copy: none

Defines the problem beni faces: when can an update to a pure aggregate be done in place without anyone noticing. Every later analysis in this section cites it.

### A Semantic Model of Reference Counting and Its Abstraction (detailed summary)

Paul Hudak. LFP 1986 (also a chapter in Abramsky & Hankin, Abstract Interpretation of Declarative Languages, 1987), 1986.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/319838.319876>
- Local copy: none

Abstract reference counting: approximate at compile time how many references each value has, to decide when an update can be destructive. Precise but exponential and tied to one evaluation order, it marks the slow end of the design space.

### Compile-Time Garbage Collection by Sharing Analysis

Simon B. Jones, Daniel Le Métayer. FPCA 1989, 1989.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/99370.99375>
- Local copy: none

A sharing analysis for first-order functional programs that finds cells which become garbage and can be reused in place. A direct functional-language precedent for inferring 'nobody else holds this'.

### Update Analysis and the Efficient Implementation of Functional Aggregates

Adrienne Bloss. FPCA 1989, 1989.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/99370.99373>
- Local copy: none

A path-based analysis deciding which aggregate updates can be done in place, for a lazy language. Bloss's Yale thesis with the full version was not found online.

### Single-Threaded Polymorphic Lambda Calculus

Juan C. Guzmán, Paul Hudak. LICS 1990, 1990.  
`paper` · inference, foundations · **supporting**

- Link: <https://doi.org/10.1109/LICS.1990.113759>
- Local copy: none

A type system that infers single-threadedness for polymorphic code and offers a let* form to put reads before writes. Its stated goal, mutation that feels natural and is easy to reason about, matches beni's.

### Unify and Conquer (Garbage, Updating, Aliasing, ...) in Functional Languages

Henry G. Baker. LFP 1990, 1990.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/91556.91652>
- Local copy: none

Observes that Hindley-Milner unification already computes a sharing approximation, and uses it for update-in-place and storage decisions. The idea of piggy-backing aliasing on the type unifier, with its imprecision.

### Escape Analysis on Lists

Young Gil Park, Benjamin Goldberg. PLDI 1992, 1992.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/143095.143125>
- Local copy: none

Escape analysis for higher-order functional programs on lists, deciding which list cells never outlive a call so they can be reused or stack allocated. A list-specific precedent for beni.

### Observers for Linear Types

Martin Odersky. ESOP 1992 (LNCS 582), 1992.  
`paper` · inference, foundations · **supporting**

- Link: <https://doi.org/10.1007/3-540-55253-7_23>
- Local copy: none

Lets a linear value be read by short-lived observers without counting as a use, so reads need not thread the value. The type-system version of 'reads before writes are fine'.

### Static Analysis of Logic Programs for Independent AND Parallelism

Dean Jacobs, Anno Langen. Journal of Logic Programming 13(2-3), 1992.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1016/0743-1066(92)90034-z>
- Local copy: none

The journal treatment of set-sharing analysis, used to prove two goals share no data and can run in parallel. The same question as 'does anything else hold this list'.

### Experiments with Destructive Updates in a Lazy Functional Language

Pieter H. Hartel, Willem G. Vree. Computer Languages 20(3), 1994.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1016/0096-0551(94)90003-5>
- Open access: <https://pure.uva.nl/ws/files/2850730/207_2703y.pdf>
- Local copy: `pdf/1994-hartel-experiments-with-destructive-updates-lazy.pdf`

Measures destructive updates on real applications and finds no analysis of the time handled higher-order, polymorphic, non-flat code. A sober report on how far the classic analyses got.

### Efficient Compile-Time Garbage Collection for Arbitrary Data Structures

Markus Mohnen. PLILP 1995 (LNCS 982), 1995.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1007/BFb0026824>
- Local copy: none

Extends compile-time sharing analysis to arbitrary algebraic data types with polynomial cost. Relevant because beni's lists sit inside records and union types.

### Once Upon a Type

David N. Turner, Philip Wadler, Christian Mossin. FPCA 1995, 1995.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/224164.224168>
- Open access: <https://homepages.inf.ed.ac.uk/wadler/papers/once/once.ps.gz>
- Local copy: `pdf/1995-turner-once-upon-a-type.pdf`

A type-based analysis, inferred with no annotations, that finds values used at most once. It shows how use-counting rides on Hindley-Milner inference with subsumption on usage annotations.

### Escape Analysis: Correctness Proof, Implementation and Experimental Results

Bruno Blanchet. POPL 1998, 1998.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/268946.268949>
- Open access: <https://bblanche.gitlabpages.inria.fr/publications/BlanchetPOPL98.ps.gz>
- Local copy: `pdf/1998-blanchet-escape-analysis-correctness-proof.pdf`

A proven, implemented escape analysis for a typed higher-order language (Caml), with measurements. Shows a type-guided escape analysis running fast on real programs.

### Escape Analysis for Java

Jong-Deok Choi, Manish Gupta, Mauricio Serrano, Vugranam C. Sreedhar, Sam Midkiff. OOPSLA 1999, 1999.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/320384.320386>
- Local copy: none

Connection graphs: a compact per-method summary of what escapes, composed across calls. A model for summarising each function once so callers reuse the result, as an incremental compiler needs.

### Pointer Analysis: Haven't We Solved This Problem Yet?

Michael Hind. PASTE 2001, 2001.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/379605.379665>
- Open access: <https://www.cs.cornell.edu/courses/cs711/2005fa/papers/hind-paste01.pdf>
- Local copy: `pdf/2001-hind-pointer-analysis-havent-we-solved-it.pdf`

A survey of pointer analysis precision dimensions (flow, context, field sensitivity) and open problems. Gives beni the vocabulary to say which precision its ownership check needs.

### Set-Sharing Is Redundant for Pair-Sharing

Roberto Bagnara, Patricia M. Hill, Enea Zaffanella. Theoretical Computer Science 277(1-2) (first at SAS 1997, LNCS 1302, doi 10.1007/bfb0032733), 2002.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1016/s0304-3975(00)00312-1>
- Local copy: none

Proves the costly set-sharing domain adds no precision when the only question is whether two variables share. For beni, whose question is pairwise, the cheap domain suffices.

### Simple Polymorphic Usage Analysis

Keith Wansbrough. PhD thesis, University of Cambridge (Technical Report UCAM-CL-TR-623, 2005), 2002.  
`thesis` · inference · **supporting**

- Link: <https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-623.pdf>
- Local copy: `pdf/2002-wansbrough-simple-polymorphic-usage-analysis-thesis.pdf`

The full account of a sound, practical, type-based usage analysis with 'simple polymorphism', implemented in GHC and measured on real programs. It is the most detailed record of what it takes to make use-counting inference cope with polymorphic, higher-order code.

### Static Analysis for Safe Destructive Updates in a Functional Language

Natarajan Shankar. LOPSTR 2001 (LNCS 2372), 2002.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1007/3-540-45607-4_1>
- Local copy: none

A proven-correct, higher-order, strict update analysis used in PVS's code generator, which silently copies when unsure. Shows the analysis beni wants exists for a strict higher-order language.

### Functional In-Place Update with Layered Datatype Sharing

Michal Konečný. TLCA 2003 (LNCS 2701), 2003.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1007/3-540-44904-3_14>
- Local copy: none

Extends usage aspects to data structures whose layers may be shared separately, such as a list spine owned while its elements are shared, and gives inference. Relevant to beni lists inside records and of records.

### Heap Recycling for Lazy Languages

Jurriaan Hage, Stefan Holdermans. PEPM 2008, 2008.  
`paper` · inference, errors · **supporting**

- Link: <https://doi.org/10.1145/1328408.1328436>
- Local copy: none

A light annotation for in-place reuse checked by an inferred uniqueness analysis. Its reception (users cannot predict what will compile) is the main risk of an annotation-free checker that reports errors.

### Pointer Analysis

Yannis Smaragdakis, George Balatsouras. Foundations and Trends in Programming Languages 2(1), 2015.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1561/2500000014>
- Open access: <https://yanniss.github.io/points-to-tutorial15.pdf>
- Local copy: `pdf/2015-smaragdakis-pointer-analysis.pdf`

A modern tutorial survey of points-to analysis written as Datalog rules, covering context sensitivity and heap abstraction. The best single entry point to the field.

### Optimizing Reference Counting with Borrowing

Anton Lorenzen. Master's thesis, University of Bonn, 2021.  
`thesis` · inference · **supporting**

- Link: <https://antonlorenzen.de/papers/master_thesis_perceus_borrowing.pdf>
- Local copy: `pdf/2021-lorenzen-optimizing-reference-counting-with-borrowing-thesis.pdf`
- Note: year from the PDF creation date (2021-11); thesis page gives no year

Studies borrow inference for Perceus in Koka: which parameters can be borrowed without changing reuse, and the cost of getting it wrong. A detailed account of borrow inference as an optimisation, the sister problem to inferring uniqueness for an error.

### Reference Counting with Frame Limited Reuse

Anton Lorenzen, Daan Leijen. ICFP 2022 (extended version MSR-TR-2021-30), 2022.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/3547634>
- Open access: <https://www.microsoft.com/en-us/research/wp-content/uploads/2021/11/flreuse-tr.pdf>
- Local copy: `pdf/2022-lorenzen-reference-counting-frame-limited-reuse-tr.pdf`

Introduces drop-guided reuse and a bound proving that reuse never keeps more memory alive than a frame's worth, plus borrowing inference refinements. Relevant because it shows which reuse decisions are safe to make automatically and how to state the guarantee precisely.

### Better Defunctionalization through Lambda Set Specialization

William Brandon, Benjamin Driscoll, Frank Dai, Wilson Berkow, Mae Milano. PLDI 2023, 2023.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/3591260>
- Open access: <https://escholarship.org/uc/item/9rf0m50t>
- Local copy: none
- Note: open-access copies exist (diamond OA per OpenAlex) but could not be downloaded by script; no local copy

Morphic's lambda-set specialisation, which makes every closure call first-order so whole-program analyses (including Morphic's alias and mutation analysis used by Roc) see through higher-order code. Relevant because an inferred uniqueness checker over a whole program faces the same higher-order precision problem.

### Functional Programming in Lean: Insertion Sort and Array Mutation

David Thrane Christiansen. Functional Programming in Lean (book), 2023.  
`book` · uniqueness-built, errors · **supporting**

- Link: <https://lean-lang.org/functional_programming_in_lean/Programming___-Proving___-and-Performance/Insertion-Sort-and-Array-Mutation/>
- Local copy: `text/lean-fpil-insertion-sort-array-mutation.txt` (saved 2026-10-10)
- Note: chapter year taken from the book's 2023 release; page is a living document

A tutorial chapter that shows a pure insertion sort mutating its array in place, and how an extra reference silently turns it into copying. It is the clearest worked example of the performance cliff an error-reporting checker would turn into a compile error.

### Graph IRs for Impure Higher-Order Languages: Making Aggressive Optimizations Affordable with Precise Effect Dependencies

Oliver Bračevac, Guannan Wei, Songlin Jia, Supun Abeysinghe, Yuxuan Jiang, Yuyan Bao, Tiark Rompf. OOPSLA 2023, 2023.  
`paper` · inference · **supporting**

- Link: <https://doi.org/10.1145/3622813>
- Open access: <https://www.cs.purdue.edu/homes/rompf/papers/bracevac-oopsla23.pdf>
- Local copy: `pdf/2023-bracevac-graph-irs-impure-higher-order-languages.pdf`
- Note: OpenAlex lists six authors; Rompf added from the PDF's host and research 69

Puts reachability types into a compiler IR (with separate compilation) to drive optimisation from precise aliasing facts. The compiler-side version of reachability, relevant to running the analysis inside a fast incremental compiler.

### Koka compiler: src/Core/CheckFBIP.hs

Koka contributors (Anton Lorenzen et al.). koka-lang/koka GitHub, 2023.  
`code` · inference, errors · **supporting**

- Link: <https://github.com/koka-lang/koka/blob/master/src/Core/CheckFBIP.hs>
- Local copy: none

The implementation of the fip/fbip checker, including the wording of its errors and warnings. The most concrete reference for how a compiler reports "this is not in place" in a pure functional language.

### Oxidizing OCaml: Locality

Max Slater (Jane Street). Jane Street Tech Blog, 2023-05-26, 2023.  
`blog` · uniqueness-built, inference · **supporting**

- Link: <https://blog.janestreet.com/oxidizing-ocaml-locality/>
- Local copy: `text/2023-janestreet-oxidizing-ocaml-locality.txt` (saved 2026-10-10)

The first of three posts introducing modes, here locality (stack allocation and escape), with the inference story told for working programmers. Background for the mode vocabulary used by uniqueness.

### Reference Counting with Reuse in Roc

Jelle Teeuwissen. Master's thesis, Utrecht University (supervisor Wouter Swierstra), 2023.  
`thesis` · inference, uniqueness-built · **supporting**

- Link: <https://hdl.handle.net/20.500.12932/44634>
- Open access: <https://studenttheses.uu.nl/server/api/core/bitstreams/d159cf72-2489-4250-b974-e1b57218e5ee/content>
- Local copy: `pdf/2023-teeuwissen-reference-counting-with-reuse-in-roc-thesis.pdf`

Replaces Roc's Counting-Immutable-Beans reference counting with Perceus plus drop-guided reuse and measures the result. A first-hand account of how Roc decides in-place updates without telling the user, the design the owner would turn into an error.

### The Functional Essence of Imperative Binary Search Trees

Anton Lorenzen, Daan Leijen, Wouter Swierstra, Sam Lindley. PLDI 2024, 2024.  
`paper` · uniqueness-built · **supporting**

- Link: <https://doi.org/10.1145/3656398>
- Open access: <https://www.microsoft.com/en-us/research/wp-content/uploads/2024/05/fiptree-full.pdf>
- Local copy: `pdf/2024-lorenzen-functional-essence-imperative-binary-search-trees.pdf`

Writes splay, zip and move-to-root trees as pure fip functions with first-class constructor contexts and shows they match imperative C speed. Evidence of how much real code fits under a checked in-place discipline.

### The Koka Programming Language (book): Perceus, Reuse Analysis, FBIP

Daan Leijen. Koka documentation, 2024.  
`docs` · uniqueness-built · **supporting**

- Link: <https://koka-lang.github.io/koka/doc/book.html>
- Local copy: `text/koka-book-perceus-reuse-fbip.txt` (saved 2026-10-10)
- Note: living document; year approximate

The user-facing explanation of Perceus, reuse analysis and the FBIP style, saved as an excerpt of sections 2.4-2.6 and 3.5. Shows how Koka explains in-place update to programmers without any ownership annotations.

### Lean Language Reference: Foreign Function Interface (borrowed and owned parameters)

Lean FRO. Lean reference manual (latest), 2025.  
`docs` · uniqueness-built, inference · **supporting**

- Link: <https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/>
- Local copy: `text/lean-reference-manual-ffi-borrowing.txt` (saved 2026-10-10)
- Note: page is undated (living document)

Documents the @& borrow annotation and the owned-by-default convention at the foreign boundary, the one place Lean asks users to state ownership. Useful for where an inferred checker must take ownership facts from outside, as beni's foreign wall would.

### Roc: Functional (in-place mutation and opportunistic mutation)

Roc contributors. roc-lang.org, 2026.  
`docs` · uniqueness-built, errors · **supporting**

- Link: <https://www.roc-lang.org/functional>
- Local copy: `text/roc-functional.txt` (saved 2026-10-10)
- Note: living page; text copy saved earlier by another collector

Roc's explanation of why its values are immutable yet updated in place when unshared, and the explicit local `var` it now offers. Shows a sibling language's public position on silent cloning versus explicit control.

### Detecting Global Variables in Denotational Specifications

David A. Schmidt. ACM TOPLAS 7(2), 1985.  
`paper` · inference, foundations · **background**

- Link: <https://doi.org/10.1145/3318.3323>
- Local copy: none

Gives syntactic conditions under which a store argument is single-threaded and can become a global, mutable variable. The earliest statement of single-threadedness as a checkable property.

### An Application of Abstract Interpretation of Logic Programs: Occur Check Reduction

Harald Søndergaard. ESOP 1986 (LNCS 213), 1986.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1007/3-540-16442-1_25>
- Local copy: none

Introduces pair-sharing analysis, tracking which pairs of variables may share, to remove occur checks. The simplest sharing domain and the one later shown to be as precise as set-sharing for pair questions.

### Accurate and Efficient Approximation of Variable Aliasing in Logic Programs **[unverified]**

Dean Jacobs, Anno Langen. NACLP 1989 (MIT Press), 1989.  
`paper` · inference · **background**

- Link: none found online
- Local copy: none
- Unverified: MIT Press proceedings with no DOI; existence known from citations and the JLP 1992 version only

Introduces the set-sharing abstract domain for which variables may share structure. The origin of sharing analysis by abstract interpretation.

### On Determining Lifetime and Aliasing of Dynamically Allocated Data in Higher-Order Functional Specifications

Alain Deutsch. POPL 1990, 1990.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1145/96709.96725>
- Local copy: none

An abstract interpretation that computes lifetime and aliasing for higher-order functional programs with dynamically allocated data. One of the first analyses to handle sharing in higher-order code.

### Compile-Time Derivation of Variable Dependency Using Abstract Interpretation

Kalyan Muthukumar, Manuel Hermenegildo. Journal of Logic Programming 13(2-3), 1992.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1016/0743-1066(92)90035-2>
- Local copy: none

Combines sharing with freeness information and reports precision and cost on real programs in the &-Prolog compiler. Follows their ICLP 1991 paper 'Combined determination of sharing and freeness of program variables through abstract interpretation'.

### A Uniform Treatment of Order of Evaluation and Aggregate Update

M. Draghicescu, S. Purushothaman. Theoretical Computer Science 118(2), 1993.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1016/0304-3975(93)90110-f>
- Local copy: none

Combines strictness-style order-of-evaluation information with update analysis for first-order lazy programs. Exponential in the worst case, showing why precise analyses were abandoned for type-based ones.

### Program Analysis and Specialization for the C Programming Language

Lars Ole Andersen. PhD thesis, DIKU, University of Copenhagen (DIKU report 94/19), 1994.  
`thesis` · inference · **background**

- Link: <https://www.cs.cornell.edu/courses/cs711/2005fa/papers/andersen-thesis94.pdf>
- Local copy: `pdf/1994-andersen-program-analysis-specialization-c.pdf`
- Note: DIKU report 94/19 has no DOI; the link is the copy a Cornell course page hosts.

Introduces inclusion-based (subset) points-to analysis, the precise cubic-time baseline for alias analysis. Beni's sharing question is a points-to question, so this is the standard reference for the precise end.

### 'Use-Once' Variables and Linear Objects: Storage Management, Reflection and Multi-Threading

Henry G. Baker. ACM SIGPLAN Notices 30(1), 1995.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/199818.199860>
- Local copy: none

An informal argument for use-once variables as a programming discipline that makes storage management and updates cheap. Background on the programmer-facing side of linearity.

### Compile-Time Garbage Collection for Lazy Functional Languages

G. W. Hamilton. IWMM 1995 (LNCS 986), 1995.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1007/3-540-60368-9_21>
- Local copy: none

Usage and sharing analysis for reusing cells in a lazy language, following his 1991 work with Jones on necessity analysis. Background showing the same analyses in the lazy setting beni does not have.

### On the Complexity of Escape Analysis

Alain Deutsch. POPL 1997, 1997.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1145/263699.263750>
- Local copy: none

Shows that a classic escape analysis can be computed in O(n log^2 n) instead of exponential time. A reference point for what precision costs in a fast compiler.

### A Type-Based Escape Analysis for Functional Languages

John Hannan. Journal of Functional Programming 8(3), 1998.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1017/s0956796898003025>
- Local copy: none

Expresses escape analysis as a type annotation system with inference, rather than abstract interpretation. Shows the analysis can live in the same machinery as the type checker.

### Escape Analysis for Object-Oriented Languages: Application to Java

Bruno Blanchet. OOPSLA 1999, 1999.  
`paper` · inference · **background**

- Link: <https://doi.org/10.1145/320384.320387>
- Open access: <https://bblanche.gitlabpages.inria.fr/publications/BlanchetOOPSLA99.ps.gz>
- Local copy: `pdf/1999-blanchet-escape-analysis-for-object-oriented-languages.pdf`

Applies the same escape analysis to Java, using types to bound which objects can escape. Background on scaling escape analysis to a whole program.

### A Type System for Bounded Space and Functional In-Place Update

Martin Hofmann. ESOP 2000 (LNCS 1782); extended in Nordic Journal of Computing 7(4), 2000.  
`paper` · foundations, inference · **background**

- Link: <https://doi.org/10.1007/3-540-46425-5_11>
- Local copy: none

LFPL: a linear language where explicit space tokens let every constructor reuse a freed cell, so programs run in place. The fully explicit end of the spectrum, the opposite of what beni wants.

### Outperforming Imperative with Pure Functional Languages

Richard Feldman. Strange Loop 2021, 2021.  
`talk` · uniqueness-built · **background**

- Link: <https://www.youtube.com/watch?v=vzfy4EKwG_Y>
- Local copy: none
- Note: title verified, video not watched (as in research 69)

Roc's creator explains opportunistic in-place mutation, Perceus and Morphic to a general audience. Context for how the Roc team sold silent in-place update.

### The Lean 4 Theorem Prover and Programming Language

Leonardo de Moura, Sebastian Ullrich. CADE-28 (LNCS 12699), 2021.  
`paper` · uniqueness-built · **background**

- Link: <https://doi.org/10.1007/978-3-030-79876-5_37>
- Open access: <https://publikationen.bibliothek.kit.edu/1000142109/141380002>
- Local copy: `pdf/2021-demoura-lean4-theorem-prover-and-programming-language.pdf`

The system description of Lean 4, including its "functional but in place" runtime and destructive updates on unshared values. Background for why Lean chose a silent run-time check over a static guarantee.

### Signals and Threads, Episode 13: Memory Management (with Stephen Dolan)

Ron Minsky, Stephen Dolan. Signals and Threads podcast, 2022-01-05, 2022.  
`talk` · uniqueness-built · **background**

- Link: <https://signalsandthreads.com/memory-management/>
- Local copy: `text/2022-signals-and-threads-memory-management.txt` (saved 2026-10-10)

A podcast transcript where an OxCaml designer discusses GC, allocation and the motivation for modes. Background on why Jane Street wanted ownership in OCaml at all.

### Exploring Perceus for OCaml

Elton Pinto, Daan Leijen. ML Family Workshop 2023, 2023.  
`paper` · uniqueness-built · **background**

- Link: <https://www.microsoft.com/en-us/research/wp-content/uploads/2023/09/ocamlrc.pdf>
- Local copy: `pdf/2023-pinto-exploring-perceus-for-ocaml.pdf`

A workshop study of porting Perceus reference counting and reuse to an OCaml-like language. Shows what happens to reuse when a language was not designed around it.

### FP²: Fully in-Place Functional Programming (ICFP 2023 talk)

Anton Lorenzen. ICFP 2023, 2023.  
`talk` · uniqueness-built · **background**

- Link: <https://www.youtube.com/watch?v=XmVc4-_3HgE>
- Local copy: none
- Note: link taken from the author's home page; video not watched

The conference talk for FP², walking through the fip check on examples. A quick way to see what the compile-time in-place error looks like to a user.

### Tail Recursion Modulo Context: An Equational Approach

Daan Leijen, Anton Lorenzen. POPL 2023, 2023.  
`paper` · uniqueness-built · **background**

- Link: <https://doi.org/10.1145/3571233>
- Open access: <https://www.microsoft.com/en-us/research/wp-content/uploads/2023/07/trmc-popl23.pdf>
- Local copy: `pdf/2023-leijen-tail-recursion-modulo-context.pdf`

Generalises tail-recursion-modulo-cons to arbitrary contexts and relies on uniqueness of the context being filled to update it in place. Relevant because beni's tail-call loop and List building could use the same in-place contexts once uniqueness is known.

### Tail Recursion Modulo Context: An Equational Approach (extended version)

Daan Leijen, Anton Lorenzen. JFP 35, e22, 2025.  
`paper` · uniqueness-built · **background**

- Link: <https://doi.org/10.1017/S0956796825100117>
- Open access: <https://antonlorenzen.de/papers/trmc-jfp.pdf>
- Local copy: `pdf/2025-leijen-tail-recursion-modulo-context-extended.pdf`

The journal version of TRMC with full proofs and more instantiations. Background for the same reason as the POPL paper.

### morphic-lang/morphic (Morphic compiler)

William Brandon, Benjamin Driscoll, et al.. GitHub, 2026.  
`code` · inference · **background**

- Link: <https://github.com/morphic-lang/morphic>
- Local copy: none
- Note: year is the last-checked date, not a release

The research compiler behind lambda-set specialisation and the 2026 borrow-inference paper. Code to read for how an annotation-free whole-program ownership pass is structured.

### refactor: port borrow inference to LCNF (lean4 PR #12413) **[unverified]**

Henrik Böving (hargoniX). leanprover/lean4 GitHub, merged 2026-02-11, 2026.  
`code` · inference · **background**

- Link: <https://github.com/leanprover/lean4/pull/12413>
- Local copy: `text/2026-lean4-pr12413-port-borrow-inference-to-lcnf.txt` (saved 2026-10-10)
- Unverified: author's full name inferred from the GitHub handle

Moves Lean's borrow inference from its low-level IR to the LCNF intermediate form, with instruction-count benchmarks in the review thread. Shows where in a pipeline an inferred ownership pass lives in a production compiler and that it is still being reworked in 2026.

## 4. Rust and its formal models

### RFC 2094: Non-lexical lifetimes

Niko Matsakis. Rust RFCs, 2017.  
`rfc` · rust, inference · **core reading**

- Link: <https://rust-lang.github.io/rfcs/2094-nll.html>
- Local copy: `text/2017-rust-rfc-2094-non-lexical-lifetimes.txt` (saved 2026-10-10)

The design document for Rust's current borrow checker: a borrow lasts only as long as the reference is live on the control-flow graph, computed by liveness and outlives constraints over MIR. It is the nearest worked specification of a flow-sensitive, fully inferred 'is this value still in use here' analysis inside a production compiler, including its problem cases.

### An alias-based formulation of the borrow checker

Niko Matsakis. Baby Steps blog, 2018.  
`blog` · rust, inference · **core reading**

- Link: <https://smallcultfollowing.com/babysteps/blog/2018/04/27/an-alias-based-formulation-of-the-borrow-checker/>
- Local copy: `text/2018-matsakis-alias-based-formulation-borrow-checker.txt` (saved 2026-10-10)

The founding Polonius post: regions are reframed as sets of loans ('origins'), and an error is a live loan invalidated at a point, all expressed as Datalog rules. It is the clearest declarative statement of 'error when something still holding the old value is used after the change', which is beni's question.

### Oxide: The Essence of Rust

Aaron Weiss, Olek Gierczak, Daniel Patterson, Amal Ahmed. arXiv 1903.00982 (latest draft 2021), 2019.  
`paper` · rust, foundations · **core reading**

- Link: <https://arxiv.org/abs/1903.00982>
- Open access: <https://arxiv.org/pdf/1903.00982>
- Local copy: `pdf/2019-weiss-oxide-essence-of-rust.pdf`

A source-level formal model of Rust's borrow checking in which regions are sets of loans ('provenances'), proven sound and checked against rustc's test suite. The cleanest type-system statement of a Polonius-style check, small enough to adapt.

### Modelling Rust's Reference Ownership Analysis Declaratively in Datalog

Amanda Stjerna (published as Albin Stjerna). MSc thesis, Uppsala University, 2020.  
`thesis` · rust, inference · **core reading**

- Link: <https://uu.diva-portal.org/smash/record.jsf?pid=diva2:1684081>
- Open access: <https://uu.diva-portal.org/smash/get/diva2:1684081/FULLTEXT02.pdf>
- Local copy: `pdf/2020-stjerna-modelling-rust-ownership-datalog.pdf`
- Note: DiVA lists 2020; an earlier draft dated Nov 2019 circulates on the Rust Zulip

Adds initialisation and liveness to Polonius, ties it to Oxide, and measures about 12,000 crates: roughly 64% of functions create no references at all. That measurement argues for a cheap first pass with the precise analysis only where needed.

### The Usability of Ownership

Will Crichton. HATRA 2020 (SPLASH workshop), 2020.  
`paper` · rust, errors · **core reading**

- Link: <https://arxiv.org/abs/2011.06171>
- Open access: <https://arxiv.org/pdf/2011.06171>
- Local copy: `pdf/2020-crichton-usability-of-ownership.pdf`

A short position paper on why ownership is hard to learn and what research on its usability is missing. Frames the error-message problem for any ownership checker.

### A Lightweight Formalism for Reference Lifetimes and Borrowing in Rust

David J. Pearce. ACM TOPLAS 43(1), 2021.  
`paper` · rust, foundations · **core reading**

- Link: <https://doi.org/10.1145/3443420>
- Open access: <https://whileydave.com/publications/Pea21_TOPLAS_preprint.pdf>
- Local copy: `pdf/2021-pearce-lightweight-formalism-reference-lifetimes-borrowing.pdf`

A small flow-sensitive calculus covering moves, copies, mutable and shared borrows, reborrowing and lifetimes, with a soundness proof. Small enough to read as a recipe for a flow-sensitive checker over a simple core language.

### A Grounded Conceptual Model for Ownership Types in Rust

Will Crichton, Gavin Gray, Shriram Krishnamurthi. OOPSLA 2023 (PACMPL 7), 2023.  
`paper` · rust, errors · **core reading**

- Link: <https://doi.org/10.1145/3622841>
- Open access: <https://cs.brown.edu/people/sk/Publications/Papers/Published/cgk-grounded-model-rust-ownership/paper.pdf>
- Local copy: `pdf/2023-crichton-grounded-conceptual-model-ownership-rust.pdf`

Finds that learners misunderstand why programs are rejected, then teaches ownership as read/write/own permissions on paths that change at each program point, visualised by Aquascope, and evaluates it in the Rust Book. The strongest evidence on how to explain an ownership error to someone who never wrote an annotation.

### Polonius revisited, part 1

Niko Matsakis. Baby Steps blog, 2023.  
`blog` · rust, inference, recent · **core reading**

- Link: <https://smallcultfollowing.com/babysteps/blog/2023/09/22/polonius-part-1/>
- Local copy: `text/2023-matsakis-polonius-revisited-part-1.txt` (saved 2026-10-10)

Restates Polonius as a location-sensitive extension of NLL rather than a separate Datalog engine, after the 2018 formulation proved too slow. Directly about trading precision for speed in a production ownership checker.

### The Rust Programming Language, Brown University experimental edition

Steve Klabnik, Carol Nichols, Chris Krycho; experiment by Will Crichton, Gavin Gray, Shriram Krishnamurthi. rust-book.cs.brown.edu, 2026.  
`book` · rust, errors · **core reading**

- Link: <https://rust-book.cs.brown.edu/>
- Local copy: `text/2026-rust-book-brown-experiment-intro.txt` (saved 2026-10-10)

The Rust Book with quizzes and Aquascope permission diagrams, used to study learners at scale; chapter 4 (saved: what-is-ownership, references-and-borrowing, fixing-ownership-errors) teaches ownership as permissions and catalogues how to fix common ownership errors. The 'fixing ownership errors' chapter is a ready list of the error kinds learners hit and the fixes they need.

### Non-lexical lifetimes based on liveness (and the rest of the 2016–2017 NLL series)

Niko Matsakis. Baby Steps blog, 2016.  
`blog` · rust, inference · **supporting**

- Link: <https://smallcultfollowing.com/babysteps/blog/2016/05/04/non-lexical-lifetimes-based-on-liveness/>
- Local copy: `text/2016-matsakis-nll-based-on-liveness.txt` (saved 2026-10-10)

Proposes that a reference's lifetime is the set of points where it is live, computed by ordinary liveness analysis. This is the key idea that makes 'still held by someone' a flow-sensitive question rather than a scope question. The rest of the 2016–2017 NLL series is saved beside it: 'adding the outlives relation' (2016-05-09), 'using liveness and location' (2017-02-21) and 'draft RFC and prototype available' (2017-07-11), as text/2016-matsakis-nll-adding-outlives-relation.txt, text/2017-matsakis-nll-liveness-and-location.txt and text/2017-matsakis-nll-draft-rfc-and-prototype.txt.

### Non-lexical lifetimes: introduction

Niko Matsakis. Baby Steps blog, 2016.  
`blog` · rust · **supporting**

- Link: <https://smallcultfollowing.com/babysteps/blog/2016/04/27/non-lexical-lifetimes-introduction/>
- Local copy: `text/2016-matsakis-nll-introduction.txt` (saved 2026-10-10)

First post of the NLL series, laying out the three problem cases that lexical lifetimes rejected although they were safe. The problem cases are a ready list of false errors an overly coarse ownership checker produces.

### RFC 2025: Enable nested method calls (two-phase borrows)

Niko Matsakis. Rust RFCs, 2017.  
`rfc` · rust · **supporting**

- Link: <https://rust-lang.github.io/rfcs/2025-nested-method-calls.html>
- Local copy: `text/2017-rust-rfc-2025-nested-method-calls-two-phase-borrows.txt` (saved 2026-10-10)

Makes `vec.push(vec.len())` legal by splitting a mutable borrow into a reservation and a later activation, so shared reads may happen in between. It shows how a strict ownership rule had to be loosened for an everyday call shape, which an inferred checker for `List` updates would meet in the same form. Also saved: Matsakis's blog post 'Nested method calls via two-phase borrowing' (2017, text/2017-matsakis-two-phase-borrowing.txt) and the rustc-dev-guide two-phase borrows chapter (text/2026-rustc-dev-guide-two-phase-borrows.txt).

### Polonius and region errors

Niko Matsakis. Baby Steps blog, 2019.  
`blog` · rust, errors · **supporting**

- Link: <https://smallcultfollowing.com/babysteps/blog/2019/01/17/polonius-and-region-errors/>
- Local copy: `text/2019-matsakis-polonius-and-region-errors.txt` (saved 2026-10-10)

Extends Polonius to report errors where a function's declared lifetime relations are violated, and discusses how to explain such errors. Relevant to how an analysis's facts can be turned back into a message.

### Aeneas: Rust Verification by Functional Translation

Son Ho, Jonathan Protzenko. ICFP 2022 (PACMPL 6), 2022.  
`paper` · rust, foundations · **supporting**

- Link: <https://doi.org/10.1145/3547647>
- Open access: <https://arxiv.org/pdf/2206.07185>
- Local copy: `pdf/2022-ho-aeneas-rust-verification-functional-translation.pdf`

Translates safe Rust into pure functional code by giving borrows 'backward functions' that rebuild the owner after a mutable borrow ends. It shows the converse of beni's problem: ownership-checked mutation is exactly expressible as pure value updates.

### Modular Information Flow through Ownership

Will Crichton, Marco Patrignani, Maneesh Agrawala, Pat Hanrahan. PLDI 2022, 2022.  
`paper` · rust, inference · **supporting**

- Link: <https://doi.org/10.1145/3519939.3523445>
- Open access: <https://arxiv.org/pdf/2111.13662>
- Local copy: `pdf/2022-crichton-modular-information-flow-ownership.pdf`

Uses function signatures' ownership types to analyse information flow modularly, without looking into callees, and measures the loss in precision as small. Evidence that a modular, signature-only ownership analysis is accurate enough in practice; code at github.com/willcrichton/flowistry.

### Aquascope: interactive visualizations of Rust at compile-time and run-time

Cognitive Engineering Lab (Will Crichton, Gavin Gray et al.). GitHub / cel.cs.brown.edu, 2023.  
`code` · rust, errors · **supporting**

- Link: <https://github.com/cognitive-engineering-lab/aquascope>
- Open access: <https://cel.cs.brown.edu/aquascope/>
- Local copy: `text/2026-aquascope-readme.txt` (saved 2026-10-10)

The tool that draws per-line permission changes and the point where a borrow conflict occurs, built on rustc's borrow-check facts (site saved as text/2023-aquascope-site.txt). A working example of turning ownership-analysis facts into a picture a learner can follow.

### Polonius revisited, part 2

Niko Matsakis. Baby Steps blog, 2023.  
`blog` · rust, inference, recent · **supporting**

- Link: <https://smallcultfollowing.com/babysteps/blog/2023/09/29/polonius-part-2/>
- Local copy: `text/2023-matsakis-polonius-revisited-part-2.txt` (saved 2026-10-10)

Works the new formulation through the canonical problem cases and sketches how it handles loops and conditional returns. Pairs with part 1.

### Polonius update

Rémy Rakic, Niko Matsakis. Inside Rust blog, 2023.  
`blog` · rust, recent · **supporting**

- Link: <https://blog.rust-lang.org/inside-rust/2023/10/06/polonius-update/>
- Local copy: `text/2023-rust-inside-rust-polonius-update.txt` (saved 2026-10-10)

The working group's account of why the Datalog Polonius stalled on performance and the plan to ship it in stages inside rustc. A frank record of what precision cost in a real compiler.

### Borrow checking without lifetimes

Niko Matsakis. Baby Steps blog, 2024.  
`blog` · rust, recent · **supporting**

- Link: <https://smallcultfollowing.com/babysteps/blog/2024/03/04/borrow-checking-without-lifetimes/>
- Local copy: `text/2024-matsakis-borrow-checking-without-lifetimes.txt` (saved 2026-10-10)

Sketches a borrow checker whose types name places ('borrowed from x') instead of lifetime variables. Relevant because place-based reasoning is closer to what a user of an annotation-free language can read in an error.

### Profiling Programming Language Learning

Will Crichton, Shriram Krishnamurthi. OOPSLA 2024 (PACMPL 8), 2024.  
`paper` · rust, errors, recent · **supporting**

- Link: <https://doi.org/10.1145/3649812>
- Open access: <https://arxiv.org/pdf/2401.01257>
- Local copy: `pdf/2024-crichton-profiling-programming-language-learning.pdf`

Uses quizzes embedded in the Rust Book, answered by tens of thousands of readers, to find where learners struggle, with ownership a leading trouble spot. A method for measuring whether ownership explanations work.

### Sound Borrow-Checking for Rust via Symbolic Semantics

Son Ho, Aymeric Fromherz, Jonathan Protzenko. ICFP 2024 (PACMPL 8), 2024.  
`paper` · rust, foundations, recent · **supporting**

- Link: <https://doi.org/10.1145/3674640>
- Open access: <https://arxiv.org/pdf/2404.02680>
- Local copy: `pdf/2024-ho-sound-borrow-checking-symbolic-semantics.pdf`

Proves that Aeneas's symbolic execution is a sound borrow checker, with joins at loops handled by an abstraction step. An alternative to dataflow formulations: borrow checking as abstract interpretation over symbolic values.

### Place Capability Graphs: A General-Purpose Model of Rust's Ownership and Borrowing Guarantees **[unverified]**

Zachary Grannan, Aurel Bílý, Jonáš Fiala, Jasper Geer, Markus de Medeiros, Peter Müller, Alexander J. Summers. arXiv 2503.21691, 2025.  
`paper` · rust, recent · **supporting**

- Link: <https://arxiv.org/abs/2503.21691>
- Open access: <https://arxiv.org/pdf/2503.21691>
- Local copy: `pdf/2025-grannan-place-capability-graphs.pdf`
- Unverified: final venue not confirmed (arXiv v5); arXiv lists the second author as Aurea Bílá

A per-program-point graph of which places hold which capabilities, built from rustc's borrow-check results and meant as a shared model for analysis tools. A concrete data structure for 'who can still read or write this place here'.

### Tree Borrows

Neven Villani, Johannes Hostert, Derek Dreyer, Ralf Jung. PLDI 2025 (PACMPL 9), 2025.  
`paper` · rust, foundations, recent · **supporting**

- Link: <https://doi.org/10.1145/3735592>
- Open access: <https://research.ralfj.de/papers/2025-pldi-tree-borrows.pdf>
- Local copy: `pdf/2025-villani-tree-borrows.pdf`

Replaces Stacked Borrows' stack with a tree of permissions and rejects 54% fewer test cases across the 30,000 most-downloaded crates while keeping most optimisations. Evidence that a stricter aliasing rule rejected a large measured share of code people consider correct. Also saved: Jung's 2023 blog post introducing it (text/2023-jung-blog-tree-borrows.txt).

### Enabling the next iteration of the borrow checker on nightly

Jack Huey (for the Polonius working area). Rust Blog, 2026.  
`blog` · rust, recent · **supporting**

- Link: <https://blog.rust-lang.org/2026/08/04/enabling-polonius-alpha-on-nightly/>
- Local copy: `text/2026-rust-blog-polonius-alpha-nightly.txt` (saved 2026-10-10)

Announces Polonius Alpha on nightly ahead of stabilisation: flow-sensitive outlives checking, with performance judged acceptable and no diagnostic changes observed. The latest data point on how long precise ownership analysis took to make fast enough.

### rustc-dev-guide: MIR borrow check

Rust compiler team. Rust Compiler Development Guide, 2026.  
`docs` · rust · **supporting**

- Link: <https://rustc-dev-guide.rust-lang.org/borrow-check.html>
- Local copy: `text/2026-rustc-dev-guide-mir-borrow-check.txt` (saved 2026-10-10)

Overview of how rustc's borrow checker is staged: MIR building, move and initialization tracking, region inference, then the borrow-conflict pass. It is the shortest map of the pass order a production ownership checker uses.

### rustc-dev-guide: Region inference (NLL)

Rust compiler team. Rust Compiler Development Guide, 2026.  
`docs` · rust, inference · **supporting**

- Link: <https://rustc-dev-guide.rust-lang.org/borrow-check/region-inference.html>
- Local copy: `text/2026-rustc-dev-guide-region-inference.txt` (saved 2026-10-10)

Explains how NLL regions are inferred as sets of program points by solving outlives constraints with SCCs. Useful for how lifetimes are inferred without annotation inside one function body; the error-reporting subpage is still a stub, which is itself a finding.

### rustc-dev-guide: Tracking moves and initialization

Rust compiler team. Rust Compiler Development Guide, 2026.  
`docs` · rust · **supporting**

- Link: <https://rustc-dev-guide.rust-lang.org/borrow-check/moves-and-initialization.html>
- Local copy: `text/2026-rustc-dev-guide-moves-and-initialization.txt` (saved 2026-10-10)

Describes the move paths and the 'maybe uninitialized' dataflow rustc uses to report use-after-move (E0382). It is the direct analogue of a 'used after it was consumed' check for a uniqueness checker.

### The Polonius book

Polonius working group. rust-lang.github.io, 2026.  
`docs` · rust, inference · **supporting**

- Link: <https://rust-lang.github.io/polonius/>
- Local copy: `text/2026-polonius-book-relations.txt` (saved 2026-10-10)

Documentation of the Datalog Polonius: its input facts, relations and rules (saved: the relations chapter; also saved intro and current-status pages as 2026-polonius-book-intro.txt and 2026-polonius-book-current-status.txt). It is the exact rule set behind the 2018 formulation. The Datalog implementation is at https://github.com/rust-lang/polonius (checked 200).

### Patina: A Formalization of the Rust Programming Language

Eric Reed. University of Washington tech report UW-CSE-15-03-02, 2015.  
`report` · rust, foundations · **background**

- Link: <https://dada.cs.washington.edu/research/tr/2015/03/UW-CSE-15-03-02.pdf>
- Local copy: `pdf/2015-reed-patina-formalization-rust.pdf`

An early formal model of pre-1.0 Rust's ownership, borrowing and initialisation. Historical background for later models.

### RustBelt: Securing the Foundations of the Rust Programming Language

Ralf Jung, Jacques-Henri Jourdan, Robbert Krebbers, Derek Dreyer. POPL 2018 (PACMPL 2), 2018.  
`paper` · rust, foundations · **background**

- Link: <https://doi.org/10.1145/3158154>
- Open access: <https://plv.mpi-sws.org/rustbelt/popl18/paper.pdf>
- Local copy: `pdf/2018-jung-rustbelt.pdf`

A machine-checked semantic soundness proof for a Rust core language and for standard-library types that use unsafe code. Background on what 'the borrow checker is sound' means; little direct bearing on inference.

### RustHorn: CHC-based Verification for Rust Programs (with RustHornBelt)

Yusuke Matsushita, Takeshi Tsukada, Naoki Kobayashi. ESOP 2020 (LNCS 12075); extended in TOPLAS 2021 (doi 10.1145/3462205), 2020.  
`paper` · rust, foundations · **background**

- Link: <https://doi.org/10.1007/978-3-030-44914-8_18>
- Open access: <https://arxiv.org/pdf/2002.09002>
- Local copy: `pdf/2020-matsushita-rusthorn.pdf`

Models a mutable borrow as a pair of the current value and a 'prophecy' of its final value, so ownership-checked programs become pure logic. Another demonstration that borrow-checked mutation and pure updates are interchangeable. Its soundness proof including unsafe code is RustHornBelt (Matsushita, Denis, Jourdan, Dreyer, PLDI 2022, doi 10.1145/3519939.3523704, DOI-OK), saved as pdf/2022-matsushita-rusthornbelt.pdf from https://people.mpi-sws.org/~dreyer/papers/rusthornbelt/paper.pdf.

### Stacked Borrows: An Aliasing Model for Rust

Ralf Jung, Hoang-Hai Dang, Jeehoon Kang, Derek Dreyer. POPL 2020 (PACMPL 4), 2020.  
`paper` · rust, foundations · **background**

- Link: <https://doi.org/10.1145/3371109>
- Open access: <https://plv.mpi-sws.org/rustbelt/stacked-borrows/paper.pdf>
- Local copy: `pdf/2020-jung-stacked-borrows.pdf`

A run-time aliasing discipline for unsafe Rust that justifies compiler optimisations, checked by the Miri interpreter. Shows how a too-strict aliasing rule was measured against real crates.

### Understanding and Evolving the Rust Programming Language

Ralf Jung. PhD thesis, Saarland University, 2020.  
`thesis` · rust, foundations · **background**

- Link: <https://doi.org/10.22028/D291-31946>
- Open access: <https://research.ralfj.de/phd/thesis-screen.pdf>
- Local copy: `pdf/2020-jung-understanding-and-evolving-rust-thesis.pdf`

Collects RustBelt and Stacked Borrows with an accessible introduction to Rust's ownership model and lifetime logic. The best single reference for the semantics behind borrowing.

### Non-lexical lifetimes (NLL) fully stable

Niko Matsakis (for the NLL working group). Rust Blog, 2022.  
`blog` · rust, errors · **background**

- Link: <https://blog.rust-lang.org/2022/08/05/nll-by-default/>
- Local copy: `text/2022-rust-blog-nll-by-default.txt` (saved 2026-10-10)

Records the removal of the old borrow checker's 'migrate mode', which had been kept partly for its error messages. Shows that diagnostics quality held back a checker swap for years.

### Revisiting Program Slicing with Ownership-based Information Flow

Will Crichton. PhD thesis, Stanford University, 2022.  
`thesis` · rust, inference · **background**

- Link: <https://willcrichton.net/assets/pdf/dissertation.pdf>
- Local copy: `pdf/2022-crichton-revisiting-program-slicing-ownership-thesis.pdf`
- Note: title and year from Crichton's CV; Stanford repository record not checked

Crichton's dissertation, building on Flowistry, on using ownership types to make program slicing modular and precise. The brief guessed a Brown 2024 thesis; his PhD is Stanford 2022 and the Brown work is postdoctoral.

### RefinedRust: A Type System for High-Assurance Verification of Rust Programs

Lennard Gäher, Michael Sammler, Ralf Jung, Robbert Krebbers, Derek Dreyer. PLDI 2024 (PACMPL 8), 2024.  
`paper` · rust, foundations, recent · **background**

- Link: <https://doi.org/10.1145/3656422>
- Open access: <https://plv.mpi-sws.org/refinedrust/paper-refinedrust.pdf>
- Local copy: `pdf/2024-gaher-refinedrust.pdf`

A refinement type system over Rust, proven in Iris, that verifies functional correctness including unsafe code. Background on ownership as a foundation for verification.

### Rust project goals 2025h1, 2025h2 and 2026: Polonius

Rémy Rakic, Amanda Stjerna, Niko Matsakis, tiif; Jack Huey (types champion). Rust project goals, 2026.  
`docs` · rust, recent · **background**

- Link: <https://goals.rust-lang.org/2026/polonius.html>
- Local copy: `text/2026-rust-project-goal-polonius.txt` (saved 2026-10-10)

The 2026 goal for stabilising Polonius Alpha. Records the current state and remaining work. The 2025h1 and 2025h2 goal pages are saved too (text/2025-rust-project-goal-polonius-2025h1.txt, -2025h2.txt; goals.rust-lang.org/2025h1/Polonius.html and /2025h2/polonius.html, both 200).

## 5. Mutable value semantics and other languages

### Clojure: Transient Data Structures

Rich Hickey. clojure.org reference, 2009.  
`docs` · mvs · **core reading**

- Link: <https://clojure.org/reference/transients>
- Local copy: `text/clojure-transients.txt` (saved 2026-10-10)
- Note: year is when transients were introduced (Clojure 1.1); page undated

Transients let code mutate a private copy of a persistent collection in place and then freeze it, with the rule that the old handle must not be used again, checked only partly at runtime. The pitfall it documents is the same use-after-edit beni wants to turn into a compile error.

### Ownership Manifesto

John McCall. swiftlang/swift docs/OwnershipManifesto.md, 2017.  
`spec` · mvs · **core reading**

- Link: <https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift/main/docs/OwnershipManifesto.md>
- Local copy: `text/2017-swift-ownership-manifesto.txt` (saved 2026-10-10)

Swift's plan for adding ownership to a language whose values are copy-on-write with reference counting and uniqueness tests: the law of exclusivity, shared and owned values, and non-copyable types. It is the closest precedent to beni's situation, a language that already has value semantics and wants to make in-place update predictable.

### SE-0176: Enforce Exclusive Access to Memory

John McCall. Swift Evolution (implemented in Swift 4.0), 2017.  
`rfc` · mvs, errors · **core reading**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0176-enforce-exclusive-access-to-memory.md>
- Local copy: `text/2017-swift-se0176-enforce-exclusive-access.txt` (saved 2026-10-10)

Makes overlapping accesses to the same variable, where one is a modification, an error: statically where possible and dynamically otherwise. Shows which exclusivity violations a compiler can catch without annotations and which it had to leave to runtime checks.

### Linear Haskell: Practical Linearity in a Higher-Order Polymorphic Language

Jean-Philippe Bernardy, Mathieu Boespflug, Ryan R. Newton, Simon Peyton Jones, Arnaud Spiwack. POPL 2018 (PACMPL 2), 2018.  
`paper` · mvs, foundations · **core reading**

- Link: <https://doi.org/10.1145/3158093>
- Open access: <https://arxiv.org/pdf/1710.09756>
- Local copy: `pdf/2017-bernardy-linear-haskell.pdf`

Puts linearity on function arrows rather than on types, so linear and ordinary code share data types, and shows in-place mutable arrays behind a pure interface. The main design alternative to uniqueness on types, and its paper explains why they chose arrows.

### Memory Management in Lobster

Wouter van Oortmerssen. aardappel.github.io/lobster, 2019.  
`docs` · mvs, inference · **core reading**

- Link: <https://aardappel.github.io/lobster/memory_management.html>
- Local copy: `text/lobster-memory-management.txt` (saved 2026-10-10)
- Note: page has no date; year approximate

Lobster infers ownership for reference counting at compile time, with no annotations, picking an owner per value and treating other uses as borrows to remove most count operations. The closest existing compiler to inferring ownership with no user annotations, though it optimises rather than reporting errors.

### Swift 5 Exclusivity Enforcement

Andrew Trick. swift.org blog, 2019.  
`blog` · mvs, errors · **core reading**

- Link: <https://www.swift.org/blog/swift-5-exclusivity/>
- Local copy: `text/2019-swift-blog-swift5-exclusivity.txt` (saved 2026-10-10)

Explains how Swift 5 turned exclusivity checks on in release builds, with examples of the compile-time errors and runtime traps users meet and why the rule enables copy-on-write optimisation. Practical evidence of how an exclusivity error reads to ordinary programmers and what it costs.

### Implementation Strategies for Mutable Value Semantics

Dimi Racordon, Denys Shabalin, Daniel Zheng, Dave Abrahams, Brennan Saeta. Journal of Object Technology 21(2), 2022.  
`paper` · mvs · **core reading**

- Link: <https://doi.org/10.5381/jot.2022.21.2.a2>
- Open access: <https://www.jot.fm/issues/issue_2022_02/article2.pdf>
- Local copy: `pdf/2022-racordon-implementation-strategies-mutable-value-semantics.pdf`

Defines mutable value semantics (values never share mutable state, in-place mutation through exclusive access, no first-class references) and compares implementation strategies, including copy-on-write with uniqueness checks. It is the clearest statement of the semantic model beni already has, and of what the compiler must prove to mutate a value in place without anyone observing it.

### Linearly Qualified Types: Generic Inference for Capabilities and Uniqueness

Arnaud Spiwack, Csongor Kiss, Jean-Philippe Bernardy, Nicolas Wu, Richard A. Eisenberg. ICFP 2022 (PACMPL 6), 2022.  
`paper` · mvs, inference, recent · **core reading**

- Link: <https://doi.org/10.1145/3547626>
- Open access: <https://arxiv.org/pdf/2103.06127>
- Local copy: `pdf/2022-spiwack-linearly-qualified-types.pdf`

Adds linear constraints that the type checker infers and threads implicitly, so uniqueness tokens need not be passed by hand. Directly about inferring uniqueness inside a Hindley–Milner style checker, which is what beni proposes.

### SE-0366: consume operator to end the lifetime of a variable binding

Michael Gottesman, Andrew Trick, Joe Groff. Swift Evolution (implemented in Swift 5.9), 2022.  
`rfc` · mvs, errors · **core reading**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0366-move-function.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0366-move-function.md>
- Local copy: `text/2022-swift-se0366-consume-operator.txt` (saved 2026-10-10)

Adds `consume x`, which ends a binding's lifetime and makes any later use a compile error with a use-after-consume diagnostic. A model for the error beni would report when an old List is used after an in-place edit.

### SE-0377: borrowing and consuming parameter ownership modifiers

Michael Gottesman, Joe Groff. Swift Evolution (implemented in Swift 5.9), 2022.  
`rfc` · mvs · **core reading**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0377-parameter-ownership-modifiers.md>
- Local copy: `text/2022-swift-se0377-borrowing-consuming-parameters.txt` (saved 2026-10-10)

Lets a function declare whether it borrows or consumes each parameter, which Swift otherwise picks by convention. These are exactly the per-parameter facts an inferring checker for beni would compute and record in interfaces instead of asking for.

### Borrow checking Hylo

Dimi Racordon, Dave Abrahams. IWACO 2023 (SPLASH 2023 workshop), 2023.  
`talk` · mvs, inference, errors · **core reading**

- Link: <https://2023.splashcon.org/details/iwaco-2023-papers/5/Borrow-checking-Hylo>
- Open access: <https://www.youtube.com/watch?v=oFupPFniD9s>
- Local copy: none
- Note: The event page says a file is attached but it loads only through the site's JavaScript; no static PDF link was found, so only the page and the ACM SIGPLAN video are recorded.

Describes how Hylo checks lifetime and exclusivity with an abstract interpreter over its IR, using ghost instructions, so programs need no lifetime annotations. It is the closest existing design to an annotation-free ownership checker that reports errors, run as a separate pass after type checking.

### How Austral's Linear Type Checker Works

Fernando Borretti. borretti.me, 2023.  
`blog` · mvs, errors · **core reading**

- Link: <https://borretti.me/article/how-australs-linear-type-checker-works>
- Local copy: `text/2023-borretti-austral-linear-type-checker.txt` (saved 2026-10-10)

A walkthrough of a real linearity checker: per-variable use states across if, case, loops and borrows, and the errors it reports. A compact, implementable reference for the shape of beni's checking pass.

### Explicit copies mode

Kavon Farvardin and Swift forums participants. Swift Forums, 2025.  
`thread` · mvs, errors, recent · **core reading**

- Link: <https://forums.swift.org/t/explicit-copies-mode/81779>
- Open access: <https://forums.swift.org/raw/81779?page=1>
- Local copy: `text/2025-swift-forums-explicit-copies-mode.txt` (saved 2026-10-10)

A 2025 prototype in which the Swift compiler reports every implicit copy as an error, with the exact diagnostic text, so performance-minded code must write `copy` where it accepts one. The closest shipped analogue to beni's proposal to make a hidden List copy a compile error, including user reactions.

### Safe Manual Memory Management in Cyclone

Nikhil Swamy, Michael Hicks, Greg Morrisett, Dan Grossman, Trevor Jim. Science of Computer Programming 62(2), 2006.  
`paper` · mvs · **supporting**

- Link: <https://doi.org/10.1016/j.scico.2006.02.003>
- Open access: <https://www.cs.umd.edu/projects/PL/cyclone/scp.pdf>
- Local copy: `pdf/2006-swamy-safe-manual-memory-management-cyclone.pdf`

Adds unique (tracked) pointers and reference counting to Cyclone's regions, and reports on using them in real programs. One of the earliest experience reports on unique pointers with flow-sensitive checking in a practical language.

### Deny Capabilities for Safe, Fast Actors

Sylvan Clebsch, Sophia Drossopoulou, Sebastian Blessing, Andy McNeil. AGERE! 2015 (SPLASH workshop), 2015.  
`paper` · mvs, foundations · **supporting**

- Link: <https://doi.org/10.1145/2824815.2824816>
- Open access: <https://www.ponylang.io/media/papers/fast-cheap.pdf>
- Local copy: `pdf/2015-clebsch-deny-capabilities-safe-fast-actors.pdf`

Pony's reference capabilities, defined by what other aliases are denied, including `iso` for a uniquely held value and `recover` for regaining uniqueness. Recover is a working example of inferring that a freshly built value is unique.

### Nim Destructors and Move Semantics

Andreas Rumpf (Araq). nim-lang.org docs, 2020.  
`docs` · mvs, inference · **supporting**

- Link: <https://nim-lang.org/docs/destructors.html>
- Local copy: `text/nim-destructors-move-semantics.txt` (saved 2026-10-10)
- Note: living document; year when ARC became default track

Specifies how Nim's ARC/ORC turns copies into moves at a value's last read, using a control-flow analysis with `sink` parameters inferred where possible. A shipped example of inferred last-use moves, including the rules users find surprising.

### Native Implementation of Mutable Value Semantics

Dimitri Racordon, Denys Shabalin, Daniel Zheng, Dave Abrahams, Brennan Saeta. ICOOOLPS 2021, 2021.  
`paper` · mvs · **supporting**

- Link: <https://arxiv.org/abs/2106.12678>
- Open access: <https://arxiv.org/pdf/2106.12678>
- Local copy: `pdf/2021-racordon-native-implementation-mutable-value-semantics.pdf`

A four-page workshop paper showing how a language with mutable value semantics (Val, later Hylo) compiles to native code that avoids copies by static reasoning about exclusivity. Short evidence that uniqueness can be established by the compiler rather than the programmer in a value-oriented language.

### Austral Language Specification

Fernando Borretti. austral-lang.org, 2022.  
`spec` · mvs · **supporting**

- Link: <https://austral-lang.org/spec/spec.html>
- Local copy: `text/2022-austral-spec.txt` (saved 2026-10-10)
- Note: living document; year is when the language was introduced

The full Austral specification, including its linearity rules and their rationale. The rules section is a precise model of use-once checking with borrows.

### Introducing Austral: A Systems Language with Linear Types and Capabilities

Fernando Borretti. borretti.me, 2022.  
`blog` · mvs · **supporting**

- Link: <https://borretti.me/article/introducing-austral>
- Local copy: `text/2022-borretti-introducing-austral.txt` (saved 2026-10-10)

Introduces Austral, a language whose linearity checker is deliberately small enough to hold in one's head. Its argument for simple, explainable rules applies to keeping beni's uniqueness errors understandable.

### Value Semantics: Safety, Independence, Projection, & Future of Programming

Dave Abrahams. CppCon 2022, 2022.  
`talk` · mvs · **supporting**

- Link: <https://www.youtube.com/watch?v=QthAU-t3PQ4>
- Local copy: none

Abrahams argues that value semantics gives local reasoning and safety, and that in-place mutation through projections keeps it fast. The argument for why beni's immutable values can be updated in place without changing what programs mean.

### Linear Constraints: the problem with O(1) freeze

Arnaud Spiwack. Tweag blog, 2023.  
`blog` · mvs, recent · **supporting**

- Link: <https://www.tweag.io/blog/2023-01-26-linear-constraints-freeze/>
- Local copy: `text/2023-tweag-linear-constraints-freeze.txt` (saved 2026-10-10)

Explains why freezing a mutable array into an immutable one in constant time is hard to make safe with linear types. Exactly the boundary beni meets between an in-place List edit and an ordinary shared List.

### Reference Capabilities for Flexible Memory Management

Ellen Arvidsson, Elias Castegren, Sylvan Clebsch, Sophia Drossopoulou, James Noble, Matthew J. Parkinson, Tobias Wrigstad. OOPSLA 2023 (PACMPL 7), 2023.  
`paper` · mvs, recent · **supporting**

- Link: <https://doi.org/10.1145/3622846>
- Open access: <https://arxiv.org/pdf/2309.02983>
- Local copy: `pdf/2023-arvidsson-reference-capabilities-flexible-memory-management.pdf`

Verona's type system: objects live in isolated regions, a capability system controls aliasing within and between regions, and a whole region can move. Region-level isolation is an alternative granularity to per-value uniqueness for large structures.

### SE-0390: Noncopyable structs and enums

Joe Groff, Michael Gottesman, Andrew Trick, Kavon Farvardin. Swift Evolution (implemented in Swift 5.9), 2023.  
`rfc` · mvs, errors · **supporting**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0390-noncopyable-structs-and-enums.md>
- Local copy: `text/2023-swift-se0390-noncopyable-structs-enums.txt` (saved 2026-10-10)

Introduces `~Copyable` types that the compiler tracks as unique, with rules for consuming, borrowing and mutating them. A detailed, shipped rule set for unique values in a language that otherwise copies freely.

### What Vale Taught Me About Linear Types, Borrowing, and Memory Safety

Evan Ovadia. verdagon.dev blog, 2023.  
`blog` · mvs · **supporting**

- Link: <https://verdagon.dev/blog/linear-types-borrowing>
- Local copy: `text/2023-verdagon-linear-types-borrowing.txt` (saved 2026-10-10)

A language designer's account of how linear types and borrowing relate, and what a borrow checker really buys. Clear prose on the design space beni's checker sits in.

### Cpp2 (cppfront): Functions, parameter passing and definite last use

Herb Sutter. hsutter.github.io/cppfront, 2024.  
`docs` · mvs, inference · **supporting**

- Link: <https://hsutter.github.io/cppfront/cpp2/functions/>
- Local copy: `text/cppfront-cpp2-functions-parameter-passing.txt` (saved 2026-10-10)
- Note: year approximate

Cpp2's in/inout/out/move/forward parameters, with the compiler moving from a variable automatically at its definite last use. Another shipped instance of inferring a move from last use without user annotation.

### Gren 0.4.5: Performance, Debugging, Web Crypto **[unverified]**

Gren team. gren-lang.org news, 2024.  
`blog` · mvs, recent · **supporting**

- Link: <https://gren-lang.org/news/240826_gren_045>
- Local copy: `text/2024-gren-045.txt` (saved 2026-10-10)
- Unverified: the saved post shows no byline; author not confirmed

Release notes for Gren, an Elm descendant compiling to JavaScript, including its array-backed collections and performance work. The nearest sibling language to beni, useful for what it did and did not do about in-place update.

### Hylo language specification

Hylo contributors. github.com/hylo-lang/specification, 2024.  
`spec` · mvs · **supporting**

- Link: <https://github.com/hylo-lang/specification>
- Open access: <https://raw.githubusercontent.com/hylo-lang/specification/main/spec.md>
- Local copy: `text/2024-hylo-specification.txt` (saved 2026-10-10)
- Note: the year is approximate; the spec is a living document

The working specification of Hylo, including its rules for bindings, access effects and exclusivity. Gives precise wording for the law of exclusivity in a value-semantics language, which beni's checker would enforce on List.

### Hylo language tour: Bindings

Hylo contributors. docs.hylo-lang.org, 2024.  
`docs` · mvs · **supporting**

- Link: <https://docs.hylo-lang.org/language-tour/bindings>
- Local copy: `text/2024-hylo-tour-bindings.txt` (saved 2026-10-10)
- Note: year is the docs site as read in 2026; the page carries no date

The tour page for let, var, inout and sink bindings, which state how a name may use a value. Shows the small vocabulary Hylo exposes for ownership, useful when deciding what beni would infer instead of asking for.

### Hylo language tour: Functions and methods

Hylo contributors. docs.hylo-lang.org, 2024.  
`docs` · mvs · **supporting**

- Link: <https://docs.hylo-lang.org/language-tour/functions-and-methods>
- Local copy: `text/2024-hylo-tour-functions-and-methods.txt` (saved 2026-10-10)
- Note: year is the docs site as read in 2026; the page carries no date

Explains Hylo's parameter passing conventions (let, inout, sink, set) and method bundles, where one name has a mutating and a consuming variant chosen by how the result is used. Method bundles are a direct model for choosing an in-place or copying List operation from context.

### hylo-lang/hylo: the Hylo compiler

Hylo contributors. GitHub, 2024.  
`code` · mvs, inference · **supporting**

- Link: <https://github.com/hylo-lang/hylo>
- Local copy: none
- Note: year approximate; active repository

The Hylo compiler, written in Swift, including the IR passes that check lifetimes and exclusivity. The place to read how an annotation-free checker is actually built and what diagnostics it emits.

### Immer: Pitfalls

Michel Weststrate and Immer contributors. immerjs.github.io, 2024.  
`docs` · mvs · **supporting**

- Link: <https://immerjs.github.io/immer/pitfalls>
- Local copy: `text/immer-pitfalls.txt` (saved 2026-10-10)
- Note: docs undated

The documented ways Immer's copy-on-write drafts go wrong in JavaScript, such as returning or keeping drafts and mutating outside a producer. Shows the failure modes of in-place update of persistent values with only runtime checks, in beni's target platform.

### Pony tutorial: Reference capabilities and Recovering capabilities

Pony contributors. tutorial.ponylang.io, 2024.  
`docs` · mvs, errors · **supporting**

- Link: <https://tutorial.ponylang.io/reference-capabilities/reference-capabilities>
- Open access: <https://tutorial.ponylang.io/reference-capabilities/recovering-capabilities>
- Local copy: `text/pony-tutorial-reference-capabilities.txt` (saved 2026-10-10)
- Note: docs carry no date

The user-facing explanation of Pony's six capabilities and of `recover` blocks (second page saved as text/pony-tutorial-recovering-capabilities.txt). Shows how a language teaches uniqueness to users, and a known source of hard-to-read errors.

### SE-0427: Noncopyable Generics

Kavon Farvardin, Tim Kientzle, Slava Pestov. Swift Evolution (implemented in Swift 6.0), 2024.  
`rfc` · mvs · **supporting**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0427-noncopyable-generics.md>
- Local copy: `text/2024-swift-se0427-noncopyable-generics.txt` (saved 2026-10-10)

Extends generics so type parameters may be noncopyable, making copyability a suppressible default constraint. Shows the cost of uniqueness meeting polymorphism, which an inferred checker must handle for generic List functions.

### SE-0432: Borrowing and consuming pattern matching for noncopyable types

Joe Groff. Swift Evolution (implemented in Swift 6.0), 2024.  
`rfc` · mvs · **supporting**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0432-noncopyable-switch.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0432-noncopyable-switch.md>
- Local copy: `text/2024-swift-se0432-borrowing-consuming-pattern-matching.txt` (saved 2026-10-10)

Defines when a `switch` borrows its subject and when it consumes it, and how pattern bindings inherit that. Directly relevant to beni's `case` on a List with `[ x, …rest ]`, where the checker must decide whether the match keeps the original alive.

### Designing Hylo, a programming language for safe systems programming

Dimi Racordon. PLSS 2025 (ECOOP 2025 workshop), 2025.  
`talk` · mvs, recent · **supporting**

- Link: <https://2025.ecoop.org/details/plss-2025-papers/12/Designing-Hylo-a-programming-language-for-safe-systems-programming>
- Open access: <https://www.youtube.com/watch?v=c_t5T5I0ffA>
- Local copy: none

A 2025 talk by Hylo's lead designer on the language's design choices, including how safety is checked. The most recent first-hand account of where Hylo's ownership model landed.

### GHC User's Guide: Linear types (LinearTypes extension)

GHC developers. downloads.haskell.org GHC user's guide, 2025.  
`docs` · mvs · **supporting**

- Link: <https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/linear_types.html>
- Local copy: `text/ghc-users-guide-linear-types.txt` (saved 2026-10-10)
- Note: tracks the latest GHC; year approximate

The reference for linear types as shipped in GHC, including its listed limitations (no inference of multiplicities for let, limited case support). Shows what linear typing in a real lazy compiler did and did not manage to infer.

### Mojo manual: Ownership and Value semantics

Modular. mojolang.org / docs.modular.com, 2025.  
`docs` · mvs · **supporting**

- Link: <https://mojolang.org/docs/manual/values/ownership/>
- Open access: <https://mojolang.org/docs/manual/values/value-semantics/>
- Local copy: `text/mojo-manual-ownership.txt` (saved 2026-10-10)
- Note: docs.modular.com redirects to mojolang.org; year approximate

Mojo's argument conventions (read, mut, owned) and the `^` transfer operator, with the compiler inserting copies or moves at last use (value-semantics page saved as text/mojo-manual-value-semantics.txt). A recent language that infers moves from last use, the same move beni would make silently.

### Cyclone: A Safe Dialect of C

Trevor Jim, Greg Morrisett, Dan Grossman, Michael Hicks, James Cheney, Yanling Wang. USENIX Annual Technical Conference 2002, 2002.  
`paper` · mvs · **background**

- Link: <https://www.usenix.org/legacy/event/usenix02/full_papers/jim/jim.pdf>
- Local copy: `pdf/2002-jim-cyclone-safe-dialect-of-c.pdf`

Overview of Cyclone as a safe C, including its experience porting code and the annotation cost users paid. Background for how much checking users tolerate.

### Idris 1 documentation: Uniqueness Types (experimental)

Idris developers. idris.readthedocs.io v0.9.19, 2015.  
`docs` · uniqueness-built · **background**

- Link: <https://idris.readthedocs.io/en/v0.9.19/reference/uniqueness-types.html>
- Local copy: `text/2015-idris1-uniqueness-types.txt` (saved 2026-10-10)
- Note: year from the version number

Idris 1's experimental Clean-style uniqueness types with UniqueType and borrowed values, later removed. A short record of a uniqueness system added to a dependently typed language and abandoned.

### Applied Type System: An Approach to Practical Programming with Theorem-Proving

Hongwei Xi. arXiv 1703.08683, 2017.  
`paper` · mvs · **background**

- Link: <https://arxiv.org/abs/1703.08683>
- Open access: <https://arxiv.org/pdf/1703.08683>
- Local copy: `pdf/2017-xi-applied-type-system.pdf`

The framework behind ATS, whose linear types and views let functional code manipulate memory in place safely. Background on linear types in an ML-family language; annotation-heavy, the opposite end from beni's goal.

### Introduction to ARC/ORC in Nim

Danil Yarantsev (guest post). Nim blog, 2020.  
`blog` · mvs · **background**

- Link: <https://nim-lang.org/blog/2020/10/15/introduction-to-arc-orc-in-nim.html>
- Local copy: `text/2020-nim-blog-arc-orc.txt` (saved 2026-10-10)

A readable introduction to Nim's move to compile-time-inserted reference counting with move semantics. Background for the destructors document.

### Keynote: A Future of Value Semantics and Generic Programming (Parts 1 and 2)

Dave Abrahams. C++Now 2022, 2022.  
`talk` · mvs · **background**

- Link: <https://www.youtube.com/watch?v=4Ri8bly-dJs>
- Open access: <https://www.youtube.com/watch?v=GsxYnEAZoNI>
- Local copy: none

A two-part keynote on independence of values, regularity and how a language designed around value semantics differs from C++ and Swift. Background for the design stance behind Val/Hylo; the oa field holds Part 2.

### Vale's Higher RAII, the pattern that saved me a vital 5 hours in the 7DRL Challenge

Evan Ovadia. verdagon.dev blog, 2022.  
`blog` · mvs · **background**

- Link: <https://verdagon.dev/blog/higher-raii-7drl>
- Local copy: `text/2022-verdagon-higher-raii.txt` (saved 2026-10-10)

Shows linear types used for protocols that must be completed, in a real game jam program. Background on what linearity buys beyond memory.

### Zero-Cost Borrowing with Vale Regions (Preview)

Evan Ovadia. verdagon.dev blog, 2022.  
`blog` · mvs · **background**

- Link: <https://verdagon.dev/blog/zero-cost-borrowing-regions-overview>
- Local copy: `text/2022-verdagon-zero-cost-borrowing-regions.txt` (saved 2026-10-10)

Vale's design for treating a whole region as immutable while a function reads it, which removes per-reference checks. Relevant as a coarse-grained alternative to per-value uniqueness.

### Haskell Interlude episode 31: Arnaud Spiwack **[unverified]**

Haskell Foundation (interview with Arnaud Spiwack). Haskell Interlude podcast, 2023.  
`talk` · mvs, recent · **background**

- Link: <https://haskell.foundation/podcast/31/>
- Local copy: none
- Unverified: no written 2023-2026 retrospective on GHC linear types was found; year from search snippet

Spiwack discusses linear types in Haskell several years after they shipped, including how they compare to Rust's ownership. The nearest thing found to a retrospective from the designers.

### Linear Constraints: the problem with scopes

Arnaud Spiwack. Tweag blog, 2023.  
`blog` · mvs, recent · **background**

- Link: <https://www.tweag.io/blog/2023-03-23-linear-constraints-linearly/>
- Local copy: `text/2023-tweag-linear-constraints-linearly.txt` (saved 2026-10-10)

Follow-up on the scoping problems of linear APIs in Haskell and how linear constraints address them. Background on the ergonomic cost of uniqueness with explicit scopes.

### Type Systems for Memory Safety

Fernando Borretti. borretti.me, 2023.  
`blog` · mvs · **background**

- Link: <https://borretti.me/article/type-systems-memory-safety>
- Local copy: `text/2023-borretti-type-systems-memory-safety.txt` (saved 2026-10-10)

A survey of how languages from Ada to Rust, Cyclone and linear-typed languages enforce memory safety in their types. Useful background on the families beni's design borrows from.

### Vale's Memory Safety Strategy: Generational References and Regions

Evan Ovadia. verdagon.dev blog, 2023.  
`blog` · mvs · **background**

- Link: <https://verdagon.dev/blog/generational-references>
- Local copy: `text/2023-verdagon-generational-references-and-regions.txt` (saved 2026-10-10)
- Note: page dated July 9 2023; the original post is from 2021

Explains Vale's single-ownership model with generation-checked non-owning references and region borrowing. Background on a middle point between full static ownership and runtime checks.

### [Pitch] Non-Escapable Types and Lifetime Dependency

Andrew Trick and Swift forums participants. Swift Forums, 2024.  
`thread` · mvs · **background**

- Link: <https://forums.swift.org/t/pitch-non-escapable-types-and-lifetime-dependency/69865>
- Open access: <https://forums.swift.org/raw/69865?page=1>
- Local copy: `text/2024-swift-forums-pitch-nonescapable-lifetime-dependency.txt` (saved 2026-10-10)

The pitch thread for nonescapable types and lifetime dependence annotations, with long discussion comparing it to Rust lifetimes. Shows how much annotation burden the Swift community accepted and resisted; only the first page of posts is saved.

### Borrow checking, RC, GC, and the Eleven (!) Other Memory Safety Approaches

Evan Ovadia. verdagon.dev (grimoire), 2024.  
`blog` · mvs · **background**

- Link: <https://verdagon.dev/grimoire/grimoire>
- Local copy: `text/2024-verdagon-grimoire.txt` (saved 2026-10-10)

A catalogue of fourteen memory-safety approaches with their trade-offs, from borrow checking to uniqueness and regions. A map for placing beni's inferred uniqueness among alternatives.

### Carbon: Safety design

Carbon language contributors. carbon-language/carbon-lang docs/design/safety, 2024.  
`spec` · mvs · **background**

- Link: <https://github.com/carbon-language/carbon-lang/blob/trunk/docs/design/safety/README.md>
- Open access: <https://raw.githubusercontent.com/carbon-language/carbon-lang/trunk/docs/design/safety/README.md>
- Local copy: `text/2024-carbon-safety-design.txt` (saved 2026-10-10)
- Note: living document; year approximate

Carbon's safety goals and plan for adding memory safety incrementally to a C++ successor. Background on how a new language stages ownership checking.

### Hylo - The Safe Systems and Generic-programming Language Built on Value Semantics **[unverified]**

Dave Abrahams. C++ on Sea (keynote), 2024.  
`talk` · mvs · **background**

- Link: <https://www.youtube.com/watch?v=5lecIqUhEl4>
- Local copy: none
- Unverified: year not confirmed (C++ on Sea 2023 or 2024); video title and channel confirmed by YouTube oEmbed

A keynote presenting Hylo as a whole: value semantics, exclusivity and projections, with no lifetime annotations. Useful as an overview of what users see when ownership is checked but not written.

### Hylo language tour: Subscripts

Hylo contributors. docs.hylo-lang.org, 2024.  
`docs` · mvs · **background**

- Link: <https://docs.hylo-lang.org/language-tour/subscripts>
- Local copy: `text/2024-hylo-tour-subscripts.txt` (saved 2026-10-10)
- Note: year is the docs site as read in 2026; the page carries no date

Describes subscripts, Hylo's projections that lend a part of a value for reading or in-place update without creating a reference. Relevant to updating one element of a nested record or list in place.

### linear-base: standard library for linear types in Haskell

Tweag. Hackage, 2024.  
`code` · mvs · **background**

- Link: <https://hackage.haskell.org/package/linear-base>
- Local copy: none
- Note: year approximate

The library of linear arrays, hashmaps and resources built on GHC's linear types. Shows the API shape linear in-place collections take when users must thread values themselves.

### microsoft/verona: research programming language for concurrent ownership

Microsoft Research. GitHub, 2024.  
`code` · mvs · **background**

- Link: <https://github.com/microsoft/verona>
- Local copy: none
- Note: year approximate

The Verona research project's repository and design notes. Background only; the OOPSLA paper is the citable account.

### SE-0446: Nonescapable Types

Andrew Trick, Tim Kientzle. Swift Evolution (implemented in Swift 6.2), 2024.  
`rfc` · mvs · **background**

- Link: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md>
- Open access: <https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0446-non-escapable.md>
- Local copy: `text/2024-swift-se0446-nonescapable-types.txt` (saved 2026-10-10)

Adds `~Escapable` types that cannot outlive their scope, the base for lifetime dependence and safe views like Span. Background on how Swift added scoped borrows late and what that required.

### Capture noncopyable in closure

Swift forums participants. Swift Forums, 2025.  
`thread` · mvs, errors · **background**

- Link: <https://forums.swift.org/t/80460>
- Open access: <https://forums.swift.org/raw/80460?page=1>
- Local copy: `text/2025-swift-forums-capture-noncopyable-in-closure.txt` (saved 2026-10-10)

A short user thread hitting the error that a noncopyable value cannot be consumed inside an escaping closure. A concrete example of the closure-capture limit any uniqueness checker meets, and of how users read the diagnostic.

### Inko manual: Memory management

Yorick Peterse and Inko contributors. docs.inko-lang.org, 2025.  
`docs` · mvs · **background**

- Link: <https://docs.inko-lang.org/manual/latest/getting-started/memory-management/>
- Local copy: `text/inko-memory-management.txt` (saved 2026-10-10)
- Note: year approximate

Inko uses single ownership with moves, plus borrows checked by runtime borrow counters that panic if an owner is dropped while borrowed. A language that chose a runtime check over a static error, a contrast for beni's choice.

## 6. Error messages for ownership

### Compiler Errors for Humans

Evan Czaplicki. elm-lang.org news, 2015.  
`blog` · errors · **core reading**

- Link: <https://elm-lang.org/news/compiler-errors-for-humans>
- Local copy: `text/2015-czaplicki-compiler-errors-for-humans.txt` (saved 2026-10-10)

Elm 0.15.1's redesign of error messages: show the user's code, speak plainly, suggest a fix (text saved from the page's Elm source in the elm-lang.org repo). The house style beni inherits and any ownership error must match.

### Shape of errors to come

Sophia June Turner. Rust Blog, 2016.  
`blog` · rust, errors · **core reading**

- Link: <https://blog.rust-lang.org/2016/08/10/Shape-of-errors-to-come/>
- Local copy: `text/2016-rust-blog-shape-of-errors-to-come.txt` (saved 2026-10-10)

Announces Rust's redesigned error format, which puts the source code first with labelled spans, explicitly inspired by Elm. The design the borrow-check errors adopted.

### Error Messages Are Classifiers: A Process to Design and Evaluate Error Messages

John Wrenn, Shriram Krishnamurthi. Onward! 2017, 2017.  
`paper` · errors · **core reading**

- Link: <https://doi.org/10.1145/3133850.3133862>
- Open access: <https://cs.brown.edu/people/sk/Publications/Papers/Published/wk-error-msg-classifier/paper.pdf>
- Local copy: `pdf/2017-wrenn-error-messages-are-classifiers.pdf`

Treats an error report as a classifier with precision and recall over programs, and gives a process to measure it. The right frame for counting false ownership errors over a real code base such as core/.

### Compiler Error Messages Considered Unhelpful: The Landscape of Text-Based Programming Error Message Research

Brett A. Becker, Paul Denny, Raymond Pettit, Durell Bouchard, Dennis J. Bouvier, Brian Harrington, Amir Kamil, Amey Karkare, Chris McDonald, Peter-Michael Osera, Janice L. Pearce, James Prather. ITiCSE Working Group Reports 2019, 2019.  
`report` · errors · **core reading**

- Link: <https://doi.org/10.1145/3344429.3372508>
- Local copy: none
- Note: no open-access copy confirmed (dl.acm.org PDF returns 403 to curl)

A survey of fifty years of error-message research that distils guidelines: give context, show a fix or hint, use plain language, report at the right time. The checklist to hold an ownership message against.

### Garbage Collection Makes Rust Easier to Use: A Randomized Controlled Trial of the Bronze Garbage Collector

Michael Coblenz, Michelle L. Mazurek, Michael Hicks. ICSE 2022, 2022.  
`paper` · rust, errors · **core reading**

- Link: <https://doi.org/10.1145/3510003.3510107>
- Open access: <https://arxiv.org/pdf/2110.01098>
- Local copy: `pdf/2022-coblenz-garbage-collection-makes-rust-easier.pdf`
- Note: the brief's 'Bronze: garbage collection for Rust (OOPSLA 2021)' does not appear to exist as a separate paper; the arXiv preprint (2021) became this ICSE 2022 paper

A randomised trial with 428 students: with a GC escape hatch, a task needing shared mutable data took far less time than with the borrow checker alone. Measures the cost of an ownership rule with no easy way out, which matters for whether beni's error needs an escape hatch.

### Learning and Programming Challenges of Rust: A Mixed-Methods Study

Shuofei Zhu, Ziyi Zhang, Boqin Qin, Aiping Xiong, Linhai Song. ICSE 2022, 2022.  
`paper` · rust, errors · **core reading**

- Link: <https://doi.org/10.1145/3510003.3510164>
- Open access: <https://par.nsf.gov/servlets/purl/10321050>
- Local copy: `pdf/2022-zhu-learning-programming-challenges-rust.pdf`

Studies Stack Overflow questions, bug fixes and a 101-person survey: ownership and lifetime errors dominate, and users understand ownership errors far more often than lifetime errors. Evidence that move-style errors are explainable while lifetime errors are not.

### OxCaml documentation: Uniqueness - Pitfalls

Jane Street OxCaml team. oxcaml.org, 2025.  
`docs` · errors, uniqueness-built · **core reading**

- Link: <https://oxcaml.org/documentation/uniqueness/pitfalls/>
- Local copy: `text/oxcaml-docs-uniqueness-pitfalls.txt` (saved 2026-10-10)
- Note: living document; year approximate

Lists the surprising rejections users hit with inferred uniqueness (closures, partial application, pattern matching) and how to fix them. The best available catalogue of where an inferred uniqueness checker confuses people.

### Rust error index: E0382 (use of moved value)

Rust project. doc.rust-lang.org error codes, 2026.  
`docs` · rust, errors · **core reading**

- Link: <https://doc.rust-lang.org/error_codes/E0382.html>
- Local copy: `text/2026-rust-error-code-e0382.txt` (saved 2026-10-10)

The long-form explanation of 'use of moved value', with fixes: borrow instead, clone, or restructure. The closest Rust analogue of 'this List was used after it was updated in place'.

### rustc-dev-guide: Errors and lints

Rust compiler team. Rust Compiler Development Guide, 2026.  
`docs` · rust, errors · **core reading**

- Link: <https://rustc-dev-guide.rust-lang.org/diagnostics.html>
- Local copy: `text/2026-rustc-dev-guide-diagnostics.txt` (saved 2026-10-10)

rustc's diagnostic style guide and machinery: primary and secondary labels, notes, help, and machine-applicable suggestions. The conventions behind the borrow-check messages that users praise.

### Measuring the Effectiveness of Error Messages Designed for Novice Programmers

Guillaume Marceau, Kathi Fisler, Shriram Krishnamurthi. SIGCSE 2011, 2011.  
`paper` · errors · **supporting**

- Link: <https://doi.org/10.1145/1953163.1953308>
- Open access: <https://cs.brown.edu/people/sk/Publications/Papers/Published/mfk-measur-effect-error-msg-novice-sigcse/paper.pdf>
- Local copy: `pdf/2011-marceau-measuring-effectiveness-error-messages.pdf`

Gives a rubric for whether a student's edit after an error message was a sensible response, and applies it to DrRacket. A ready method for evaluating beni's ownership messages.

### Mind Your Language: On Novices' Interactions with Error Messages

Guillaume Marceau, Kathi Fisler, Shriram Krishnamurthi. Onward! 2011, 2011.  
`paper` · errors · **supporting**

- Link: <https://doi.org/10.1145/2048237.2048241>
- Open access: <https://cs.brown.edu/people/sk/Publications/Papers/Published/mfk-mind-lang-novice-inter-error-msg/paper.pdf>
- Local copy: `pdf/2011-marceau-mind-your-language.pdf`
- Note: brief placed it at SIGCSE 2011; it is Onward! 2011 (the SIGCSE 2011 paper is the separate 'Measuring the effectiveness...')

Observes how students read DrRacket's messages and finds vocabulary and highlighting often mislead them. Practical advice on wording and on which code to highlight.

### Compilers as Assistants

Evan Czaplicki. elm-lang.org news, 2015.  
`blog` · errors · **supporting**

- Link: <https://elm-lang.org/news/compilers-as-assistants>
- Local copy: `text/2015-czaplicki-compilers-as-assistants.txt` (saved 2026-10-10)

Elm 0.16's follow-up: type errors with hints, and type-annotation mismatch messages that read as assistance. Sets the tone bar for a new class of error.

### elm/error-message-catalog

Evan Czaplicki and contributors. GitHub, 2016.  
`code` · errors · **supporting**

- Link: <https://github.com/elm/error-message-catalog>
- Local copy: `text/2026-elm-error-message-catalog-readme.txt` (saved 2026-10-10)
- Note: start year approximate

A set of Elm programs meant to trigger every error message so their quality can be reviewed together. A model for a corpus of ownership-error fixtures.

### RFC 1644: Default and expanded errors for rustc

Sophia June Turner (Jonathan Turner). Rust RFCs, 2016.  
`rfc` · rust, errors · **supporting**

- Link: <https://rust-lang.github.io/rfcs/1644-default-and-expanded-rustc-errors.html>
- Local copy: `text/2016-rust-rfc-1644-default-and-expanded-errors.txt` (saved 2026-10-10)

Specifies the code-first error layout and a separate expanded explanation per error code. The written contract behind 'Shape of errors to come'.

### How Should Compilers Explain Problems to Developers?

Titus Barik, Denae Ford, Emerson Murphy-Hill, Chris Parnin. ESEC/FSE 2018, 2018.  
`paper` · errors · **supporting**

- Link: <https://doi.org/10.1145/3236024.3236040>
- Local copy: none

Analyses compiler errors as arguments and finds developers accept weak reasoning if a resolution is offered. Suggests an ownership error should lead with the fix.

### Obsidian: Typestate and Assets for Safer Blockchain Programming

Michael Coblenz, Reed Oei, Tyler Etzel, Paulette Koronkevich, Miles Baker, Yannick Bloem, Brad A. Myers, Joshua Sunshine, Jonathan Aldrich. ACM TOPLAS 42(3), 2020.  
`paper` · errors, foundations · **supporting**

- Link: <https://doi.org/10.1145/3417516>
- Open access: <https://arxiv.org/pdf/1909.03523>
- Local copy: `pdf/2020-coblenz-obsidian.pdf`
- Note: local PDF is the arXiv working draft (2019), not the TOPLAS version

A language with linear 'asset' types and typestate designed with user studies at each step, with a final study of programmers using ownership. Shows ownership designed and tested for usability rather than just soundness.

### Benefits and Drawbacks of Adopting a Secure Programming Language: Rust as a Case Study

Kelsey R. Fulton, Anna Chan, Daniel Votipka, Michael Hicks, Michelle L. Mazurek. SOUPS 2021 (USENIX), 2021.  
`paper` · rust, errors · **supporting**

- Link: <https://www.usenix.org/conference/soups2021/presentation/fulton>
- Open access: <https://www.usenix.org/system/files/soups2021-fulton.pdf>
- Local copy: `pdf/2021-fulton-benefits-drawbacks-adopting-rust.pdf`

Interviews and a survey of 178 developers: most found Rust harder to learn, with the borrow checker the main hurdle, but valued the safety once over it. Practitioner-level evidence on the learning cost of ownership errors.

### Rust fact vs. fiction: 5 insights from Google's Rust journey in 2022

Lars Bergstrom, Kathy Brennan. Google Open Source blog, 2023.  
`blog` · rust, errors · **supporting**

- Link: <https://opensource.googleblog.com/2023/06/rust-fact-vs-fiction-5-insights-from-googles-rust-journey-2022.html>
- Local copy: `text/2023-google-rust-fact-vs-fiction.txt` (saved 2026-10-10)

Google developer survey: most were productive in Rust within a few months, only 9% were unsatisfied with diagnostics, and ownership and borrowing ranked second among challenges after macros. A professional counterweight to the student studies.

### The most common Rust compiler errors as encountered in RustRover, part 1 **[unverified]**

JetBrains RustRover team. JetBrains blog, 2023.  
`blog` · rust, errors · **supporting**

- Link: <https://blog.jetbrains.com/rust/2023/12/14/the-most-common-rust-compiler-errors-as-encountered-in-rustrover-part-1/>
- Local copy: `text/2023-jetbrains-most-common-rust-compiler-errors.txt` (saved 2026-10-10)
- Unverified: author names not on the saved page; part 2 (ranks 5 to 1) not collected

IDE telemetry ranking the rustc error codes users hit most; part 1 covers ranks 10 to 6, with E0382 (use after move) at 6 and the higher-ranked codes left to part 2. Frequency data for which ownership errors deserve the most care.

### An Interactive Debugger for Rust Trait Errors

Gavin Gray, Will Crichton, Shriram Krishnamurthi. PLDI 2025 (PACMPL 9), 2025.  
`paper` · rust, errors, recent · **supporting**

- Link: <https://doi.org/10.1145/3729302>
- Open access: <https://arxiv.org/pdf/2504.18704>
- Local copy: `pdf/2025-gray-interactive-debugger-rust-trait-errors.pdf`

Argus lets developers explore the inference tree behind a trait error instead of reading one flattened message, and in a study they found the root cause faster. About trait errors, not ownership, but it is the recent argument for interactive rather than one-shot explanations of a failed inference.

### Rust error index: E0499, E0502, E0505 (borrow conflicts, move out while borrowed)

Rust project. doc.rust-lang.org error codes, 2026.  
`docs` · rust, errors · **supporting**

- Link: <https://doc.rust-lang.org/error_codes/E0502.html>
- Local copy: `text/2026-rust-error-code-e0502.txt` (saved 2026-10-10)

Explanations for two mutable borrows (E0499), mutable while shared (E0502) and moving a value while it is borrowed (E0505); saved as 2026-rust-error-code-e0499.txt, -e0502.txt and -e0505.txt. E0502 is the exact shape of 'changed while something else still holds the old version'.

### rustc_borrowck diagnostics: conflict_errors.rs

Rust compiler team. rust-lang/rust source, 2026.  
`code` · rust, errors · **supporting**

- Link: <https://github.com/rust-lang/rust/blob/main/compiler/rustc_borrowck/src/diagnostics/conflict_errors.rs>
- Local copy: none

The code that builds use-after-move and conflicting-borrow messages, including the 'value moved here, in previous iteration of loop' and clone suggestions. The primary source for how a production checker picks the three points (creation, conflict, later use) to show.

### Swift compiler DiagnosticsSIL.def (move-only and consume diagnostics)

Swift project. swiftlang/swift source, 2026.  
`code` · mvs, errors · **supporting**

- Link: <https://github.com/swiftlang/swift/blob/main/include/swift/AST/DiagnosticsSIL.def>
- Local copy: `text/2026-swift-diagnostics-sil-def.txt` (saved 2026-10-10)

The message table for Swift's ownership checker, including "'x' used after consume" and "'x' consumed more than once" with their notes. Concrete wording from a mutable-value-semantics language's ownership errors.

### Enhancing Syntax Error Messages Appears Ineffectual

Paul Denny, Andrew Luxton-Reilly, Dave Carpenter. ITiCSE 2014, 2014.  
`paper` · errors · **background**

- Link: <https://doi.org/10.1145/2591708.2591748>
- Local copy: none

A controlled study finding no significant effect of enhanced syntax error messages on students. The other side of the evidence: better wording alone is not guaranteed to help.

### An Effective Approach to Enhancing Compiler Error Messages

Brett A. Becker. SIGCSE 2016, 2016.  
`paper` · errors · **background**

- Link: <https://doi.org/10.1145/2839509.2844584>
- Local copy: none

A study of about 200 students reporting fewer errors and repeats with enhanced Java messages. One side of the mixed evidence on whether rewording helps.

### Identifying Barriers to Adoption for Rust through Online Discourse

Anna Zeng, Will Crichton. PLATEAU 2018, 2018.  
`paper` · rust, errors · **background**

- Link: <https://arxiv.org/abs/1901.01001>
- Open access: <https://arxiv.org/pdf/1901.01001>
- Local copy: `pdf/2018-zeng-barriers-adoption-rust-online-discourse.pdf`

Codes Reddit and Hacker News discussion of Rust and finds the borrow checker and its learning curve among the main complaints. Early, small evidence on the cost users perceive.

### Learning Rust: How Experienced Programmers Leverage Resources to Learn a New Programming Language

Parastoo Abtahi, Griffin Dietz. CHI 2020 Extended Abstracts, 2020.  
`paper` · rust, errors · **background**

- Link: <https://doi.org/10.1145/3334480.3383069>
- Local copy: none

A small diary study of experienced programmers learning Rust and the resources they turned to, with compiler messages among them. Paywalled; DOI only.

### PLIERS: A Process that Integrates User-Centered Methods into Programming Language Design

Michael Coblenz, Gauri Kambhatla, Paulette Koronkevich, Jenna L. Wise, Celeste Barnaby, Joshua Sunshine, Jonathan Aldrich, Brad A. Myers. ACM TOCHI 28(4), 2021.  
`paper` · errors · **background**

- Link: <https://doi.org/10.1145/3452379>
- Open access: <https://arxiv.org/pdf/1912.04719>
- Local copy: `pdf/2021-coblenz-pliers.pdf`

A method for designing language features with user studies, illustrated on Obsidian's ownership system. A process beni could use to test its ownership error before committing to it.

## 7. Recent work (2023–2026) and other material

### Kindly Bent to Free Us

Gabriel Radanne, Hannes Saffrich, Peter Thiemann. ICFP 2020, 2020.  
`paper` · inference, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1145/3408985>
- Open access: <https://arxiv.org/pdf/1908.09681>
- Local copy: `pdf/2020-radanne-kindly-bent-to-free-us.pdf`

Affe: an ML with affine and linear types tracked by kinds, plus borrowing regions, with ML-style type inference. A direct precedent for inferring ownership inside an HM checker.

### Functional Ownership through Fractional Uniqueness

Daniel Marshall, Dominic Orchard. OOPSLA 2024 (PACMPL 8, OOPSLA1), 2024.  
`paper` · recent, uniqueness-built · **core reading**

- Link: <https://doi.org/10.1145/3649848>
- Open access: <https://arxiv.org/pdf/2310.18166>
- Local copy: `pdf/2024-marshall-functional-ownership-fractional-uniqueness.pdf`

Granule's uniqueness with fractional permissions: a unique reference can be split into read-only shares and rejoined to regain uniqueness before an in-place update. A clean model of borrowing in a pure functional language, and of letting reads share while writes demand uniqueness.

### Uniqueness is Separation

Liam O'Connor, Pilar Selene Linares Arévalo, Christine Rizkallah. arXiv preprint 2602.06386, 2026.  
`paper` · recent, foundations, errors · **core reading**

- Link: <https://arxiv.org/abs/2602.06386>
- Open access: <https://arxiv.org/pdf/2602.06386>
- Local copy: `pdf/2026-oconnor-uniqueness-is-separation.pdf`

Proves that a uniqueness condition is exactly what makes the immutable and the mutable readings of a program indistinguishable, framed in separation logic. That statement is the contract an error message from beni's checker would explain to the user.

### Capturing Types

Aleksander Boruch-Gruszecki, Martin Odersky, Edward Lee, Ondřej Lhoták, Jonathan Brachthäuser. TOPLAS 45(4), 2023.  
`paper` · recent, foundations · **supporting**

- Link: <https://doi.org/10.1145/3618003>
- Open access: <https://plg.uwaterloo.ca/~olhotak/pubs/toplas23.pdf>
- Local copy: `pdf/2023-boruchgruszecki-capturing-types.pdf`
- Note: TOPLAS volume/issue not re-checked

The calculus behind Scala 3 capture checking: types record which capabilities a value captures. It is the foundation for Scala's separation checking, a deployed relative of reachability types.

### Degrees of Separation: A Flexible Type System for Safe Concurrency

Yichen Xu, Aleksander Boruch-Gruszecki, Martin Odersky. OOPSLA 2024 (PACMPL 8, OOPSLA1), 2024.  
`paper` · recent · **supporting**

- Link: <https://doi.org/10.1145/3649853>
- Open access: <https://arxiv.org/pdf/2308.07474>
- Local copy: `pdf/2024-xu-degrees-of-separation.pdf`

System CSC: aliases are allowed by default but tracked, and separation is enforced only where races matter. The same "track sharing, restrict only at the dangerous operation" stance as the owner's rule.

### Capture Now, Consume Later: Reachability Types with Flow-Sensitive Effects for Higher-Order Ownership Transfer **[unverified]**

Haotian Deng, Siyuan He, Songlin Jia, Yuyan Bao, Tiark Rompf. arXiv preprint 2510.08939, 2025.  
`paper` · recent, inference · **supporting**

- Link: <https://arxiv.org/abs/2510.08939>
- Open access: <https://arxiv.org/pdf/2510.08939>
- Local copy: `pdf/2025-deng-capture-now-consume-later.pdf`
- Unverified: venue not confirmed beyond arXiv

Adds flow-sensitive effects so a closure may capture a value now and consume (move) it later, a hard case for uniqueness in higher-order code. Relevant to how beni's checker would treat Lists captured in lambdas.

### Data Race Freedom à la Mode

Aïna Linn Georges, Benjamin Peters, Laila Elbeheiry, Leo White, Stephen Dolan, Richard A. Eisenberg, Chris Casinghino, François Pottier, Derek Dreyer. POPL 2025, 2025.  
`paper` · recent · **supporting**

- Link: <https://doi.org/10.1145/3704859>
- Open access: <https://iris-project.org/pdfs/2025-popl-drfcaml.pdf>
- Local copy: `pdf/2025-georges-data-race-freedom-a-la-mode.pdf`

Extends OCaml's mode system with contention and portability axes for data-race freedom, sharing the inference machinery with uniqueness. Shows the mode approach scaling to more axes while staying backward-compatible with unannotated code.

### Modal Effect Types

Wenhao Tang, Leo White, Stephen Dolan, Daniel Hillerström, Sam Lindley, Anton Lorenzen. OOPSLA 2025, 2025.  
`paper` · recent · **supporting**

- Link: <https://doi.org/10.1145/3720476>
- Open access: <https://arxiv.org/pdf/2407.11816>
- Local copy: `pdf/2025-tang-modal-effect-types.pdf`

Uses modes, the same device as OxCaml uniqueness, to track effects without effect variables in signatures. Relevant because beni already infers effect bits and might share one modal framework for effects and ownership.

### Linear Constraints

Arnaud Spiwack, Csongor Kiss, Jean-Philippe Bernardy, Nicolas Wu, Richard A. Eisenberg. arXiv preprint 2604.21467 (revised and extended version of Linearly Qualified Types), 2026.  
`paper` · inference, recent · **supporting**

- Link: <https://arxiv.org/abs/2604.21467>
- Open access: <https://arxiv.org/pdf/2604.21467>
- Local copy: `pdf/2026-spiwack-linear-constraints.pdf`

The 2026 revision of Linearly Qualified Types with a simpler formal system and constraint solver and more applications. Research 69 cites arXiv 2604.21467 as the revision; its title is "Linear Constraints", not the ICFP title.

### Scala 3 reference: Separation Checking (experimental)

Scala 3 team (EPFL LAMP). scala-lang.org, 2026.  
`docs` · recent, errors · **supporting**

- Link: <https://scala-lang.org/api/3.x/docs/experimental/capture-checking/separation-checking.html>
- Local copy: `text/scala3-docs-separation-checking.txt` (saved 2026-10-10)
- Note: living document; year approximate

The user documentation for Scala's separation checker: consume parameters, killed aliases, and the errors shown. A live example of explaining alias-based errors to users of a mainstream language.

### System Capybara: Tracking Capabilities for Separation and Freshness (Extended Version)

Yichen Xu, Oliver Bračevac, Cao Nguyen Pham, Yaoyu Zhao, Martin Odersky. arXiv preprint 2607.09383, 2026.  
`paper` · recent, inference · **supporting**

- Link: <https://arxiv.org/abs/2607.09383>
- Open access: <https://arxiv.org/pdf/2607.09383>
- Local copy: `pdf/2026-xu-system-capybara.pdf`

The formal model of Scala 3's separation checker, with consume parameters that kill aliases of their argument. The newest deployed-language design for "after this update, old references are dead".

### Typestate via Revocable Capabilities

Songlin Jia, Craig Liu, Siyuan He, Haotian Deng, Yuyan Bao, Tiark Rompf. PLDI 2026 (PACMPL 10, PLDI), 2026.  
`paper` · recent · **supporting**

- Link: <https://doi.org/10.1145/3808323>
- Open access: <https://arxiv.org/pdf/2510.08889>
- Local copy: `pdf/2026-jia-typestate-via-revocable-capabilities.pdf`

Uses reachability-tracked capabilities that can be revoked to express typestate, i.e. a value becomes unusable after an operation. Close to "the old List may not be used after an in-place edit" as a typing rule.

### Recovering Purity with Comonads and Capabilities

Vikraman Choudhury, Neelakantan Krishnaswami. ICFP 2020, 2020.  
`paper` · foundations · **background**

- Link: <https://doi.org/10.1145/3408993>
- Open access: <https://arxiv.org/pdf/1907.07283>
- Local copy: `pdf/2020-choudhury-recovering-purity-comonads-capabilities.pdf`

Shows how to carve out pure code inside an effectful language with a comonadic capability discipline. Background for the capability view of permission-to-mutate.

### Tail Modulo Cons

Frédéric Bour, Basile Clément, Gabriel Scherer. JFLA 2021, 2021.  
`paper` · uniqueness-built · **background**

- Link: <https://arxiv.org/abs/2102.09823>
- Open access: <https://arxiv.org/pdf/2102.09823>
- Local copy: `pdf/2021-bour-tail-modulo-cons.pdf`

The original design note for OCaml's TMC transformation (destination-passing for list-building recursion). Background, paired with the POPL 2025 verification.

### Oxidizing OCaml: Data Race Freedom

Max Slater (Jane Street). Jane Street Tech Blog, 2023-09-01, 2023.  
`blog` · recent · **background**

- Link: <https://blog.janestreet.com/oxidizing-ocaml-parallelism/>
- Local copy: `text/2023-janestreet-oxidizing-ocaml-data-race-freedom.txt` (saved 2026-10-10)
- Note: author not re-read from the page

The third post, using modes for a statically data-race-free parallel API. Background on how far the same inferred-mode machinery is pushed.

### Weak-linearity, globality and in-place update **[unverified]**

Hector Gramaglia. arXiv preprint 2402.16534, 2024.  
`paper` · recent, uniqueness-built · **background**

- Link: <https://arxiv.org/abs/2402.16534>
- Open access: <https://arxiv.org/pdf/2402.16534>
- Local copy: `pdf/2024-gramaglia-weak-linearity-globality-in-place-update.pdf`
- Unverified: venue unknown beyond arXiv; not read

A type system for safe in-place update in a functional language based on weak linearity and global variables. A small recent attempt at the same problem; useful for comparison, low weight.

### Destination Calculus: A Linear λ-Calculus for Purely Functional Memory Writes

Thomas Bagrel, Arnaud Spiwack. OOPSLA 2025 (PACMPL 9, OOPSLA1), 2025.  
`paper` · recent · **background**

- Link: <https://doi.org/10.1145/3720423>
- Open access: <https://arxiv.org/pdf/2503.07489>
- Local copy: `pdf/2025-bagrel-destination-calculus.pdf`

A pure calculus where functions write results into destinations (holes) safely, using modes for linearity and scope. Related to building Lists in place without exposing mutation.

### First-Order Laziness

Anton Lorenzen, Daan Leijen, Wouter Swierstra, Sam Lindley. ICFP 2025 (Distinguished Paper), 2025.  
`paper` · recent, uniqueness-built · **background**

- Link: <https://doi.org/10.1145/3747530>
- Open access: <https://antonlorenzen.de/papers/lazycons.pdf>
- Local copy: `pdf/2025-lorenzen-first-order-laziness.pdf`

Replaces thunks with lazy constructors that are updated in place when forced, combining memoisation with Koka's reuse. Shows the Koka line extending in-place reasoning to new data structures in 2025.

### Formalization and Implementation of Safe Destination Passing in Pure Functional Programming Settings

Thomas Bagrel. PhD thesis, Université de Lorraine / LORIA (tel-05455981), 2025.  
`thesis` · recent · **background**

- Link: <https://arxiv.org/abs/2601.08529>
- Open access: <https://arxiv.org/pdf/2601.08529>
- Local copy: `pdf/2025-bagrel-safe-destination-passing-thesis.pdf`

The thesis collecting destination calculus and its Linear Haskell implementation. Background on in-place construction in a pure language.

### Memory Safety: Uniqueness as Separation **[unverified]**

Pilar Selene Linares Arévalo, Arthur Azevedo de Amorim, Vincent Jackson, Liam O'Connor, Peter Schachte, Christine Rizkallah. Programming Languages and Systems (LNCS), 2025, 2025.  
`paper` · recent, foundations · **background**

- Link: <https://doi.org/10.1007/978-981-95-3585-9_1>
- Local copy: none
- Unverified: venue assumed APLAS 2025 from the LNCS 'Programming Languages and Systems' title and date; not confirmed; no open copy found

The conference precursor to "Uniqueness is Separation", relating uniqueness types to separation logic for memory safety. Paywalled; listed so the arXiv version's lineage is clear.

### Modeling Reachability Types with Logical Relations: Semantic Type Soundness, Termination, Effect Safety, and Equational Theory

Yuyan Bao, Songlin Jia, Guannan Wei, Oliver Bračevac, Tiark Rompf. OOPSLA 2025 (PACMPL 9, OOPSLA2), 2025.  
`paper` · recent, foundations · **background**

- Link: <https://doi.org/10.1145/3763116>
- Open access: <https://arxiv.org/pdf/2309.05885>
- Local copy: `pdf/2025-bao-modeling-reachability-types-logical-relations.pdf`

A semantic soundness proof for reachability types, including the equational theory that justifies optimisations. Background for the guarantee an error-reporting checker would be claiming.

### Tail Modulo Cons, OCaml, and Relational Separation Logic

Clément Allain, Frédéric Bour, Basile Clément, François Pottier, Gabriel Scherer. POPL 2025, 2025.  
`paper` · recent · **background**

- Link: <https://doi.org/10.1145/3704915>
- Open access: <https://arxiv.org/pdf/2411.19397>
- Local copy: `pdf/2025-allain-tail-modulo-cons-ocaml-relational-separation-logic.pdf`

Describes and verifies OCaml's tail-modulo-cons transformation, which builds lists with in-place writes into fresh cells. Background for in-place list construction that needs no uniqueness checking because the cell is fresh.

### A Value Trick for Modal Type Systems **[unverified]**

Anton Lorenzen, Wenhao Tang, Sam Lindley. IMLA 2026 workshop, 2026.  
`paper` · recent, inference · **background**

- Link: <https://antonlorenzen.de/papers/value-trick-imla.pdf>
- Local copy: `pdf/2026-lorenzen-value-trick-for-modal-type-systems.pdf`
- Unverified: venue taken from the author's home page only

A short workshop paper on relaxing mode restrictions for syntactic values, a usability refinement for modal systems like OxCaml's. Relevant to cutting false rejections in an inferred uniqueness checker.

### Scala 3 reference: Stateful Capabilities (experimental capture checking)

Scala 3 team (EPFL LAMP). scala-lang.org, 2026.  
`docs` · recent · **background**

- Link: <https://scala-lang.org/api/3.x/docs/experimental/capture-checking/mutability.html>
- Local copy: `text/scala3-docs-capture-checking-mutability.txt` (saved 2026-10-10)
- Note: living document; year approximate

Documents Mutable classes and update methods, the read/write distinction separation checking builds on. Companion to the separation-checking page.

## Other local copies

Pages and PDFs saved alongside an entry above (a series folded into one entry, a companion paper, a full report whose chapter is the entry). The entry's note or summary names them.

- `pdf/2011-plasmeijer-clean-2.2-language-report.pdf`
- `pdf/2022-matsushita-rusthornbelt.pdf`
- `text/2016-matsakis-nll-adding-outlives-relation.txt` — <https://smallcultfollowing.com/babysteps/blog/2016/05/09/non-lexical-lifetimes-adding-the-outlives-relation/>
- `text/2017-matsakis-nll-draft-rfc-and-prototype.txt` — <https://smallcultfollowing.com/babysteps/blog/2017/07/11/non-lexical-lifetimes-draft-rfc-and-prototype-available/>
- `text/2017-matsakis-nll-liveness-and-location.txt` — <https://smallcultfollowing.com/babysteps/blog/2017/02/21/non-lexical-lifetimes-using-liveness-and-location/>
- `text/2017-matsakis-two-phase-borrowing.txt` — <https://smallcultfollowing.com/babysteps/blog/2017/03/01/nested-method-calls-via-two-phase-borrowing/>
- `text/2023-aquascope-site.txt` — <https://cel.cs.brown.edu/aquascope/>
- `text/2023-jung-blog-tree-borrows.txt` — <https://www.ralfj.de/blog/2023/06/02/tree-borrows.html>
- `text/2025-rust-project-goal-polonius-2025h1.txt` — <https://goals.rust-lang.org/2025h1/Polonius.html>
- `text/2025-rust-project-goal-polonius-2025h2.txt` — <https://goals.rust-lang.org/2025h2/polonius.html>
- `text/2026-polonius-book-current-status.txt` — <https://rust-lang.github.io/polonius/current_status.html>
- `text/2026-polonius-book-intro.txt` — <https://rust-lang.github.io/polonius/>
- `text/2026-rust-book-brown-fixing-ownership-errors.txt` — <https://rust-book.cs.brown.edu/ch04-03-fixing-ownership-errors.html>
- `text/2026-rust-book-brown-references-and-borrowing.txt` — <https://rust-book.cs.brown.edu/ch04-02-references-and-borrowing.html>
- `text/2026-rust-book-brown-what-is-ownership.txt` — <https://rust-book.cs.brown.edu/ch04-01-what-is-ownership.html>
- `text/2026-rust-error-code-e0499.txt` — <https://doc.rust-lang.org/error_codes/E0499.html>
- `text/2026-rust-error-code-e0505.txt` — <https://doc.rust-lang.org/error_codes/E0505.html>
- `text/2026-rustc-dev-guide-two-phase-borrows.txt` — <https://rustc-dev-guide.rust-lang.org/borrow-check/two-phase-borrows.html>
- `text/mojo-manual-value-semantics.txt` — <https://mojolang.org/docs/manual/values/value-semantics.md>
- `text/pony-tutorial-recovering-capabilities.txt` — <https://tutorial.ponylang.io/reference-capabilities/recovering-capabilities>

## Checker source code

Where each checker with public source does its uniqueness, ownership or borrow work. Paths were confirmed to exist at the commit given (read on 2026-10-10); nothing is vendored.

### Clean compiler (uniqueness typing)

- Repository: <https://gitlab.science.ru.nl/clean-compiler-and-rts/compiler>
- Looked at: `master`, commit `e10f016fc88ea40a0fcd8290e1cd763e739f2c6c` (2026-10-09)
- `frontend/refmark.icl` — Reference-marking pass: counts variable occurrences per function and makes shared references non-unique (makeSharedReferencesNonUnique), reporting 'demanded attribute cannot be offered by shared object'.
- `frontend/refmark.dcl` — Interface of the reference-marking pass (makeSharedReferencesNonUnique).
- `frontend/unitype.icl` — Uniqueness attribute inference core: coercion trees over attribute variables, determineAttributeCoercions, tryToMakeUnique/NonUnique, attribute partitioning.
- `frontend/unitype.dcl` — Interface: TypeAttribute constants, CoercionTree/Coercions, coercion error codes, uniquenessErrorVar.
- `frontend/analunitypes.icl` — Sign and propagation classification of type definitions (how uniqueness propagates through type constructor arguments).
- `frontend/analtypes.icl` — Type definition analysis (partitioning, expansion, kinds) feeding the attribute properties of type definitions.
- `frontend/typesupport.icl` — Type support: attribute environments, coercion environment creation, cleanup of inferred attributes for signatures and messages.
- `frontend/type.icl` — Main type inference driver: calls refmark after unification and emits the 'could not be coerced from non unique to unique' coercion errors.

Browsed via the GitLab API (project id 2648); refmark is called from type.icl's per-component inference (line ~3425 at this commit).

### Futhark (consumption / uniqueness checking)

- Repository: <https://github.com/diku-dk/futhark>
- Looked at: `master`, commit `e641ce0c7e41c1edf285b06cc833179bc6a30690` (2026-10-09)
- `src/Language/Futhark/TypeChecker/Consumption.hs` — Source-language consumption checker: checks a value definition does not violate consumption (in-place update) constraints; tracks aliases and infers return freshness.
- `src/Futhark/Analysis/Alias.hs` — Whole-program alias analysis over the IR, producing a program annotated with transitive aliases.
- `src/Futhark/IR/Aliases.hs` — IR representation whose patterns carry alias information and whose bodies record consumed variables.
- `src/Futhark/IR/Prop/Aliases.hs` — Building blocks for aliasing and consumption (consumedInStm, consumedInExp, consumedByLambda).
- `src/Futhark/IR/TypeCheck.hs` — IR type checker, including occurrence tracking that rejects use after consumption.
- `src/Futhark/Analysis/LastUse.hs` — Last-use analysis for array short-circuiting (memory reuse), not the checker itself.

### Lean 4 (new compiler, LCNF: borrow inference, RC, reset/reuse)

- Repository: <https://github.com/leanprover/lean4>
- Looked at: `master`, commit `c1f2fc66e14cf8632e9dd0e0702d407fdc67b9c6` (2026-10-09)
- `src/Lean/Compiler/LCNF/InferBorrow.lean` — Borrow inference on LCNF: dataflow that starts all parameters borrowed and marks them owned for tail calls, reset/reuse and performance heuristics.
- `src/Lean/Compiler/LCNF/PropagateBorrow.lean` — Propagates user-provided borrow annotations forward through a function.
- `src/Lean/Compiler/LCNF/ExplicitRC.lean` — Inserts explicit inc/dec via liveness, honouring borrowed parameters and derived borrows (Counting Immutable Beans scheme).
- `src/Lean/Compiler/LCNF/ResetReuse.lean` — Inserts reset/reuse pairs for constructor memory reuse.
- `src/Lean/Compiler/LCNF/ExpandResetReuse.lean` — Expands reset/reuse pairs into explicit unique (in-place) and shared paths.
- `src/Lean/Compiler/LCNF/CoalesceRC.lean` — Coalesces adjacent reference-count operations.

PR https://github.com/leanprover/lean4/pull/12413 'refactor: port borrow inference to LCNF', merged 2026-02-11 (merge commit cad960267bfd9bc25bc0b485e75807a0c7ac57d3), deleted src/Lean/Compiler/IR/Borrow.lean and added LCNF/InferBorrow.lean. At this commit IR/ no longer has Borrow/RC/ResetReuse files.

### Lean 4 (old IR pipeline: Borrow, RC, ResetReuse)

- Repository: <https://github.com/leanprover/lean4>
- Looked at: `tag v4.24.0`, commit `797c613eb9b6d4ec95db23e3e00af9ac6657f24b` (2025-09-22)
- `src/Lean/Compiler/IR/Borrow.lean` — Original borrow inference over the IR, per block of mutually recursive functions.
- `src/Lean/Compiler/IR/RC.lean` — Explicit RC instruction insertion (the old ExplicitRC).
- `src/Lean/Compiler/IR/ResetReuse.lean` — Reset/reuse insertion on the IR.
- `src/Lean/Compiler/IR/ExpandResetReuse.lean` — Expands reset/reuse into fast (unique) and slow paths on the IR.

ExplicitRC.lean exists only in LCNF; in the old IR the file is RC.lean.

### Koka (Perceus, reuse, FBIP check)

- Repository: <https://github.com/koka-lang/koka>
- Looked at: `dev`, commit `9c55695dd2f7d4db8d93011693d37295e2b76c53` (2026-10-01)
- `src/Backend/C/Parc.hs` — Perceus: precise reference counting insertion (dup/drop) for the C backend.
- `src/Backend/C/ParcReuse.hs` — Constructor reuse analysis (reuse tokens for in-place update).
- `src/Backend/C/ParcReuseSpec.hs` — Reuse specialisation: specialises reuse applications to write only changed fields.
- `src/Core/CheckFBIP.hs` — Checker for fip/fbip-annotated functions: reports when a function is not functional-but-in-place.
- `src/Core/Borrowed.hs` — Table of borrowed-parameter information per function; borrowing comes from user ^ annotations, not inference.

Latest tag v3.2.9 (facb7932ce6871fdb063f762a304bd8238f35fba); dev head used. No borrowed-parameter inference found: Borrowed.hs only records declared borrows.

### Roc (Rust compiler: borrow inference, inc/dec, reset/reuse, drop specialisation, Morphic alias analysis)

- Repository: <https://github.com/roc-lang/roc>
- Looked at: `tag alpha4-rolling`, commit `d73ea109cc21442da01387c1e5e911607c74692d` (2025-09-08)
- `crates/compiler/mono/src/borrow.rs` — Borrow-signature inference for procedure parameters (infer_borrow_signatures).
- `crates/compiler/mono/src/inc_dec.rs` — Reference count increment/decrement insertion (Teeuwissen's Utrecht thesis).
- `crates/compiler/mono/src/reset_reuse.rs` — Reset/reuse insertion based on Frame-Limited Reuse.
- `crates/compiler/mono/src/drop_specialization.rs` — Drop specialisation from Perceus.
- `crates/compiler/alias_analysis/src/lib.rs` — Lowers mono IR to morphic_lib to run Morphic alias/mutation analysis for in-place updates.
- `crates/vendor/morphic_lib` — Vendored morphic_lib, the alias analysis solver.

crates/ is gone from main; alpha4-rolling is the newest tag that still contains the Rust compiler.

### Roc (new Zig compiler: ARC and borrow inference on LIR)

- Repository: <https://github.com/roc-lang/roc>
- Looked at: `main`, commit `8cbd3572b2c5288c6994576c6530d55a3256cfcb` (2026-10-09)
- `src/lir/arc.zig` — ARC insertion for LIR: borrow inference plus emission of incref/decref/free.
- `src/lir/arc_solve.zig` — Borrow inference: decides owned vs borrowed for each refcounted local and each proc's signature.
- `src/lir/arc_sig.zig` — Per-proc ownership signatures (borrowed vs owned argument positions and return mode).
- `src/lir/arc_liveness.zig` — Fixpoint liveness over a compressed control graph, used by ARC.
- `src/lir/arc_certify.zig` — Debug-only certifier that re-checks emitted RC statements against the ownership rules.
- `src/lir/box_reuse.zig` — Rewrites allocation-replacement shapes to reuse an existing allocation before ARC.

No Morphic-style alias analysis found in the Zig compiler's src/ listing.

### Morphic (borrow-based RC inference, paper doi 10.1145/3798221)

- Repository: <https://github.com/morphic-lang/morphic>
- Looked at: `main`, commit `ffe4a080efefe76316a7dd87e55d7550b48cf0d7` (2026-09-29)
- `crates/morphic_backend/src/annot_modes.rs` — First pass of borrow inference: mode (owned/borrowed) and lifetime constraint generation with specialisation per SCC.
- `crates/morphic_backend/src/annot_obligations.rs` — Solves mode constraints, monomorphises by mode, and reruns lifetime inference.
- `crates/morphic_backend/src/annot_rcs.rs` — Places retains/releases from obligations and moves.
- `crates/morphic_backend/src/guard_types.rs` — Guards custom types to improve borrow-inference precision.
- `crates/morphic_backend/src/type_check_borrows.rs` — Type-checks the borrow-annotated program (internal consistency check).
- `crates/morphic_backend/src/rc_specialize.rs` — Specialises functions by storage mode into release plans.
- `crates/morphic_common/src/data/borrow_model.rs` — Small specification language for borrow signatures of built-ins.

README links the borrow paper doi 10.1145/3798221. Branches oopsla2025 (5a239772169e874bdaa54def9bd77d14a245d4a2) and oopsla2025-revision (2eb1c5db78a38ded126a08de8f93f3fbe597a7f0, 2025-07-30) hold the paper-era state.

### Morphic (whole-program mutation inference, older pipeline)

- Repository: <https://github.com/morphic-lang/morphic>
- Looked at: `branch popl2023`, commit `bf25399720c069064ff4e453537da9c4bc5f55f0` (2022-07-08)
- `src/annot_aliases.rs` — Whole-program alias analysis over the first-order AST.
- `src/annot_mutation.rs` — Mutation annotation: which values may be mutated, from the alias results.
- `src/annot_fates.rs` — Fate annotation: how each value is later used, deciding in-place versus copy.
- `src/specialize_aliases.rs` — Specialises functions by alias signature.

main reorganised into crates/ and these alias/mutation passes are not present there under these names.

### OxCaml (uniqueness and modes)

- Repository: <https://github.com/oxcaml/oxcaml>
- Looked at: `main`, commit `bb7745d9e223876eb1495bbc28fc56ae296543f1` (2026-10-09)
- `typing/uniqueness_analysis.ml` — Post-typing pass checking that identifiers used more than once are not used at mode unique (usage trees, forcing aliased, error reporting).
- `typing/uniqueness_analysis.mli` — Interface: check_uniqueness_exp, check_uniqueness_value_bindings.
- `typing/mode.ml` — Mode axes (locality, uniqueness, linearity, ...) and their lattices built on the solver.
- `typing/mode_intf.mli` — Mode interface: axes, modalities, submode and error types.
- `typing/solver.ml` — Generic lattice constraint solver for mode variables.
- `typing/solver_intf.mli` — Solver interface (Dolan and Qian, 2024).
- `typing/mode_hint.mli` — Hints that explain mode errors (pinpoints, closure descriptions).

### rustc borrow checker (NLL)

- Repository: <https://github.com/rust-lang/rust>
- Looked at: `main`, commit `69bccf03c4733f57482f9691456efcd80f86a5f6` (2026-10-09)
- `compiler/rustc_borrowck/src/lib.rs` — MIR typeck and borrowck entry; walks MIR checking accesses against live borrows.
- `compiler/rustc_borrowck/src/nll.rs` — Entry point of the NLL borrow checker: computes regions.
- `compiler/rustc_borrowck/src/region_infer/mod.rs` — Region inference: SCCs of outlives constraints and region values.
- `compiler/rustc_borrowck/src/dataflow.rs` — Borrowck dataflow state: borrows in scope, uninitialised and ever-initialised places.
- `compiler/rustc_borrowck/src/borrow_set.rs` — Set of all borrows in a body, including two-phase activations.
- `compiler/rustc_borrowck/src/polonius/mod.rs` — In-tree Polonius (location-sensitive) analysis support.
- `compiler/rustc_borrowck/src/polonius/legacy/facts.rs` — Fact generation for the legacy datalog Polonius engine.
- `compiler/rustc_borrowck/src/diagnostics/conflict_errors.rs` — Reports conflicting-borrow and use-after-move errors.
- `compiler/rustc_borrowck/src/diagnostics/explain_borrow.rs` — Explains why a value is still borrowed (later-use explanations).
- `compiler/rustc_borrowck/src/diagnostics/move_errors.rs` — Errors for moves out of borrowed content.
- `compiler/rustc_borrowck/src/diagnostics/region_errors.rs` — Lifetime/region error reporting.
- `compiler/rustc_mir_dataflow/src/impls/initialized.rs` — Maybe/ever-initialised dataflow analyses used for move checking.
- `compiler/rustc_mir_dataflow/src/impls/borrowed_locals.rs` — Dataflow of locals that may be borrowed.

The 'Borrows' dataflow analysis lives in rustc_borrowck/src/dataflow.rs at this commit, not in rustc_mir_dataflow.

### Polonius (datalog borrow checker engine)

- Repository: <https://github.com/rust-lang/polonius>
- Looked at: `main`, commit `41ae30d2cb66d82098a8b8abd2cbccf1c1a2a96f` (2026-10-02)
- `polonius-engine/src/output/naive.rs` — Naive datalog borrow analysis via Datafrog (the reference rules).
- `polonius-engine/src/output/datafrog_opt.rs` — Optimised location-sensitive variant of the analysis.
- `polonius-engine/src/output/location_insensitive.rs` — Cheap location-insensitive pre-pass that finds potential errors.
- `polonius-engine/src/output/liveness.rs` — Variable liveness computation.
- `polonius-engine/src/output/initialization.rs` — Move/initialisation analysis.
- `polonius-engine/src/output/mod.rs` — Driver selecting the algorithm variant.

Latest tag v0.7.0 (8c8eabefea17cc5e0ff43e6047f5facae07f9df1).

### Hylo (law of exclusivity and lifetimes)

- Repository: <https://github.com/hylo-lang/hylo>
- Looked at: `main`, commit `b86ff706a3a81ef6ae52e15d912988a6c6d5fe1b` (2026-07-13)
- `Sources/IR/Analysis/Module+Ownership.swift` — Ensures the Law of Exclusivity in each function, reporting errors and warnings.
- `Sources/IR/Analysis/Module+NormalizeObjectStates.swift` — Abstract interpretation ensuring objects are initialised before use and deinitialised after last use.
- `Sources/IR/Analysis/Module+CloseBorrows.swift` — Inserts end_borrow after the last use of each access.
- `Sources/IR/Analysis/Lifetime.swift` — Lifetime regions rooted at a definition (uses dominated by it).
- `Sources/IR/Analysis/Module+AccessReification.swift` — Chooses the concrete access capability for each access.
- `Sources/IR/Analysis/AbstractInterpreter.swift` — Generic abstract interpreter the ownership passes use.

### Swift move-only (noncopyable) checker

- Repository: <https://github.com/swiftlang/swift>
- Looked at: `main`, commit `e739e65153fd564ac1cb9f4140d7130e7d099e16` (2026-10-09)
- `lib/SILOptimizer/Mandatory/MoveOnlyChecker.cpp` — Mandatory SIL pass driving move-only checking of objects and addresses.
- `lib/SILOptimizer/Mandatory/MoveOnlyAddressCheckerUtils.cpp` — Move-only checking of addresses (field-sensitive liveness, consumes, reinitialisation).
- `lib/SILOptimizer/Mandatory/MoveOnlyObjectCheckerUtils.cpp` — Move-only checking of SSA object values.
- `lib/SILOptimizer/Mandatory/MoveOnlyDiagnostics.cpp` — Diagnostic emission for move-checking errors (consumed twice, used after consume).
- `lib/SILOptimizer/Mandatory/ConsumeOperatorCopyableValuesChecker.cpp` — Checks the consume operator on copyable values (no use after consume).
- `lib/SILOptimizer/Mandatory/DiagnoseStaticExclusivity.cpp` — Static diagnosis of exclusivity (overlapping access) violations.
- `include/swift/AST/DiagnosticsSIL.def` — Diagnostic texts, including the sil_movechecking_* errors (around line 890).

### Mercury (unique modes, CTGC structure reuse)

- Repository: <https://github.com/Mercury-Language/mercury>
- Looked at: `master`, commit `68c9b23e0f890eb433d31b055498a14f8c7b67e6` (2026-10-09)
- `compiler/unique_modes.m` — Checks unique-mode variables really are unique and not nondet live (referenced on backtracking); tries another mode before reporting an error.
- `compiler/mode_errors.m` — Mode error reporting, including uniqueness errors.
- `compiler/structure_reuse.m` — Package of the compile-time garbage collection / structure reuse analysis (with structure_reuse.*.m and ctgc.*.m).

### Granule (graded modal types with uniqueness and borrowing)

- Repository: <https://github.com/granule-project/granule>
- Looked at: `main`, commit `85a463f18914353669ff291677c47190fff43b23` (2026-07-21)
- `frontend/src/Language/Granule/Checker/Checker.hs` — Core bidirectional checker; checks Star (unique) and Borrow (fractional permission) types and introduces permission variables.
- `frontend/src/Language/Granule/Checker/Primitives.hs` — Built-in Uniqueness grade and uniqueness/borrowing primitives (withBorrow, splitting and joining fractional borrows).
- `frontend/src/Language/Granule/Checker/Coeffects.hs` — Context operations over coeffects (grades) used for usage accounting.

### Idris 2 (quantitative type theory linearity check)

- Repository: <https://github.com/idris-lang/Idris2>
- Looked at: `main`, commit `1c630e67c386629a0fbbc6b78a59176fde7f0a76` (2026-09-08)
- `src/Core/LinearCheck.idr` — Linearity check of elaborated terms: counts variable usages so linear names are used exactly once, and updates hole types with usage counts.

### GHC (linear types: multiplicities and usage environments)

- Repository: <https://gitlab.haskell.org/ghc/ghc>
- Looked at: `master (read via the GitHub mirror ghc/ghc)`, commit `f76464cff4a9b55bb01e612bffe0dd866a9982e3` (2026-10-08)
- `compiler/GHC/Core/Multiplicity.hs` — The semiring of multiplicities annotating arrows, with simplifying operations.
- `compiler/GHC/Core/UsageEnv.hs` — Usage environments: per-variable multiplicities with add, scale and sup.
- `compiler/GHC/Tc/Utils/Monad.hs` — tcCollectingUsage / tcScalingUsage / tcEmitBindingUsage: collect and scale usages during type checking.
- `compiler/GHC/Tc/Utils/TcMType.hs` — tcCheckUsage: checks a binder's actual usage against its declared multiplicity.
- `compiler/GHC/Tc/Utils/Unify.hs` — tcSubMult: submultiplicity constraints between multiplicities.
- `compiler/GHC/Core/Lint.hs` — Core Lint, which also lints linearity of Core.

Paths verified on the GitHub mirror at this SHA; the gitlab.haskell.org blob URL for Multiplicity.hs at this SHA returns 200. beni's references/ghc is sparse (compiler/GHC/Core/Opt only) and does not hold these files.
## Reading order

There are two tracks plus a short third one. Each step names entries above by first author and
year. Section numbers in brackets say where an entry is filed.

### Track A: the theory

The goal is to know exactly which property beni would check, and which type theory states it.

1. **What uniqueness is, as against linearity.**
   - Wadler 1990 and Wadler 1991 [1] state the goal and the trap: a linear value may still be
     shared.
   - Then read Walker 2005 [1], the textbook account of substructural systems.
   - Then read Marshall, Vollmer and Orchard 2022 [1], which separates "used once from now on"
     from "never shared until now". That distinction is the one beni's rule needs.
2. **Uniqueness as a type system.**
   - Barendsen and Smetsers 1993 and 1996 [2] give Clean's system: attributes, propagation into
     containers, and coercion from unique to shared.
   - de Vries 2007 (Redefined) and 2008 (Simplified) [2] reduce it to ordinary type inference
     with Boolean attributes. This is the version closest to a Hindley–Milner checker.
   - Harrington 2006 [1] is the logic behind it, for reference.
3. **Reading without consuming.**
   - Wadler's `let!` (1990), then Odersky 1991 and 1992 [3] on observers.
   - Then Boyland 2001 [1] on alias burying.
   - These three are the theory behind 69 §1.3 item 2 (reads before writes) and item 9
     (read-only closures).
4. **Graded and quantitative types.**
   - Atkey 2018 and McBride 2016 [1] give quantitative type theory.
   - Orchard et al. 2019 [1] is Granule.
   - Marshall and Orchard 2024 [7], fractional uniqueness, puts borrowing in the same frame.
   - Read this step to judge whether a usage count is a better carrier than a Boolean
     attribute, given that beni already infers effect bits.
5. **Ownership and permissions.**
   - Clarke et al. 2013 [1], the survey: §5 and §8 on inference and why it must choose a best
     solution.
   - Then Boyland 2003 (fractional permissions), Reynolds 2002 (separation logic) and
     Pottier 2013 (Mezzo) [1]: the vocabulary that recent papers use.
6. **Sharing in higher-order, polymorphic code.**
   - Bao et al. 2021 and Wei et al. 2024 [3] give reachability types.
   - Then Jia et al. 2026 [3] on bidirectional typing with avoidance.
   - Then Deng et al. 2025, O'Connor 2026 (Uniqueness is Separation) and Xu 2026 (Capybara)
     [7].
   - This is the current theory for 69 §5 questions 3 and 4: closures and polymorphic
     pipelines.
7. **Modes as the industrial answer.**
   - Lorenzen et al. 2024, Oxidizing OCaml [3], gives uniqueness and locality as modes inferred
     alongside types.
   - Peters et al. 2026, Mode Crossing [3], exempts element types that cannot be mutated.
   - Read with Spiwack et al. 2022 [5] and Bernardy et al. 2018 [5] to see what Linear
     Haskell chose instead and what it cost.
8. **Regions, for the precedent of whole-program inference.**
   - Tofte and Talpin 1994, then Tofte et al. 2004 (the retrospective) [1]: what happens when a
     memory property is inferred and invisible.

### Track B: algorithms that fit beni

Beni is strict and pure. Its Hindley–Milner checker already infers effect bits, the whole
program is available, and the compiler must be fast and incremental. Read with those facts in
mind.

1. **The problem in a strict language.**
   - Hudak 1985 and 1986 [3] on the aggregate update problem and abstract reference counting.
   - Bloss 1989 [3] on update analysis.
   - Sastry, Clinger and Ariola 1993 [3]: order of evaluation as the lever, which beni gets
     for free.
   - Cann 1990 (SISAL 1.2) [2]: the only measured rate of copies a static analysis could not
     remove.
2. **Inference with no annotations.**
   - Barendsen and Smetsers 1995, Uniqueness Type Inference [2]: the recipe and its known false
     errors.
   - Then de Vries 2008 [2] for partial application and the cases that need rank-2.
   - Then Futhark: Henriksen et al. 2017 and the thesis's chapters on uniqueness [2], the 2022
     and 2026 blog posts [2], and the checker source below.
3. **A best answer, not a lucky one.**
   - Aspinall and Hofmann 2002, then Aspinall, Hofmann and Konečný 2008 [3]: usage aspects,
     read-only use, and the optimistic fixpoint.
   - Wansbrough and Peyton Jones 1999 [3]: polymorphic usage inference with constraint
     solving. Read it for how the constraints are simplified so they scale.
4. **Which way the flow goes.**
   - Steensgaard 1996 against Andersen 1994 [3]: unification-based against subset-based
     sharing.
   - Then Emre et al. 2023 [3], measured evidence that the direction of flow decides
     precision.
   - Then Jones and Le Métayer 1989, Søndergaard 1986, Jacobs and Langen 1992 and Bagnara et
     al. 2002 [3]: sharing analysis by abstract interpretation, the alternative to type
     inference.
5. **Per-function summaries, and the boundary.**
   - Ullrich and de Moura 2019 [3]: Lean's borrow inference, a fixpoint over the whole program
     that is frozen at the boundary.
   - Lean PR 12413 [3] and the Lean code below show what that inference looks like now.
   - Brandon et al. 2026 [3]: fully automatic borrow inference with lifetimes. Read it with the
     Morphic source below.
6. **Why the rule must not be the optimiser.**
   - Reinking et al. 2021 (Perceus), Lorenzen and Leijen 2022 (frame-limited reuse) §3–§4, and
     Lorenzen et al. 2023 (FP²) §1.4 [3].
   - Then McCall 2017, the Ownership Manifesto, and the Swift "Explicit copies mode" thread [5].
7. **Escape, for what leaves a function.**
   - Park and Goldberg 1992 and Hannan 1998 [3] on functional programs.
   - Blanchet 1998 [3] on the correctness proof and cost.
   - Read these for the closure question, together with Track A step 6.
8. **Rust's checker as an engineering reference.**
   - RFC 2094 (NLL), then Matsakis 2018 (the alias-based formulation) and Stjerna 2020 (the
     Datalog model) [4]. Polonius is the clearest statement of borrow checking as a fixpoint
     over facts.
   - Weiss et al. 2019 (Oxide) and Pearce 2021 [4] are the smallest formal models of the same
     check.

### Track C: the error, and how to evaluate it

1. Czaplicki 2015 (both posts) and the Elm error-message catalogue [6]: the house standard.
2. Crichton 2020 and Crichton, Gray and Krishnamurthi 2023 [4]: what a user cannot tell from an
   ownership error.
3. Wrenn and Krishnamurthi 2017 [6]: treat the checker as a classifier and count its false
   errors.
4. Then read three real sets of ownership errors:
   - the rustc-dev-guide diagnostics chapter and E0382 [6];
   - the Futhark error index and the 2021 bug post [2, 6];
   - the OxCaml pitfalls page [6].
5. Zhu et al. 2022 and Coblenz et al. 2022 [6] for the measured cost of ownership errors to
   users.
