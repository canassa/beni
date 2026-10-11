The central idea is defensible, but the rules as written still contain a soundness hole: a callback can return entirely fresh storage that contains internal sharing, and `initialize` can incorrectly turn that into deep exclusivity. There is also a concrete problem with the claimed monotonicity of the summary domain.

This review follows the chapter order in ownership/main.tex. Examples and traces below are deductions from the text, not execution results. I changed no files and ran no builds.

## 1\. Deep open questions

**1\.1. The fresh-result rule admits a concrete counterexample.**

**Claim.** Freshness across callback invocations does not establish separation _within_ each callback result. The `initialize` rule in §3.8 conflates these properties.

Consider:

```
demo ⊤ =
    rows = List.initialize 1 (λ_ →
        cell = [ 0 ]
        [ cell, cell ])
    changed = List.update rows 0 (λpair →
        List.update pair 0 (λxs → [ …xs, 9 ]))
    List.foldl changed 0 (λpair total →
        total + List.foldl pair 0 (λxs n → n + List.length xs))
```

The acceptance derivation follows the displayed rules:

1. The initializer callback allocates `cell` and the list containing it. Its result provenance is `fresh₁` at the outer list and `fresh₂` at `[*]`, with distinct numbers at distinct tracked paths.
2. Consequently, it satisfies §3.8’s definition of **`g.res fresh`**. Both occurrences of `cell` collapse into the _same_ `[*]` path; the distinct-path condition does not detect the duplication.
3. The callback’s own result is correctly **not exclusive** under §3.11: its two positions share `cell`.
4. Nevertheless, `initialize` asserts `excl if g.res fresh`. That condition does not require the callback’s nested `xres` facts.
5. The outer `List.update` therefore supplies `pair` owned and recursively exclusive. This satisfies the inner update’s exclusivity requirement.
6. The inner update supplies `xs` owned, permitting the append. There are no external captures or later uses of the consumed inputs to reject it.

The concrete executions differ:

| Step | Value semantics | In-place semantics |
|---|---|---|
| After initialization | One pair containing the same `[0]` twice | Same |
| Update the first inner list | Creates `[0,9]`; second entry remains `[0]` | Changes the shared cell to `[0,9]` |
| Replace the first pair entry | `[[0,9], [0]]` | `[[0,9], [0,9]]` |
| Sum the lengths | **3** | **4** |

The second entry observes an edit intended only for the first. Neither commands nor the renderer are involved.

An implementation that additionally checks recursive exclusivity of the callback result would reject this example—but that is the missing condition. The general invariant in §3.11 cannot justify a primitive rule that establishes it incorrectly.

**Confidence: high. Author action:** Strengthen the fresh-result rules for `initialize`, `map`, related traversals, and schema construction. Require both per-invocation freshness and recursive separation of the returned structure. Add this example beside T24, T56, and T57. See §3.8 (ownership/ch-model.tex:622) and §3.11 (ownership/ch-model.tex:803).

***

**1\.2. Execution-prefix induction is a suitable foundation, but the current lemmas do not yet constitute a well-founded proof.**

**Claim.** Closure capture paths do not inherently invalidate induction over execution length. The missing piece is a sufficiently strong invariant about closures and unfinished calls.

Section 6.3 correctly avoids induction over call-tree depth. Recursive closures can have cyclic environment graphs, and callbacks can execute while their callers remain open. Neither prevents induction over individual machine steps.

However, the summary proof establishes call clauses when calls return, while the dead-alias argument needs those clauses **during** calls. For a non-returning call, “clauses 1 and 4 hold of every prefix” restates the needed result without supplying its invariant. Likewise, returning a closure must establish a contract about its _future_ calls; those calls have not occurred earlier in the prefix.

A suitable invariant would cover residual code, open frames, suspended continuations, closure environments, and permissions transferred at call entry. A step-indexed logical relation is one option; simultaneous preservation over a machine configuration is another. Capture environments should be finite graphs with a reachability relation, not objects whose validity is proved by descending through capture paths.

There is also a simpler defect in the statement of summary soundness. Clause 2 says that absent `E`, argument cells have no surviving holders except the result. But:

```
n = List.length xs
List.length xs
```

leaves the caller’s `xs` alive. The intended property must exclude **new, unreported escaping holders**, while preserving permitted holders already present in the caller.

**Confidence: high on the gaps; medium on the best formalization. Author action:** Write a small operational semantics and a simultaneous configuration invariant before extending the proof. Repair clause 2 explicitly. Mechanization would be valuable, but merely mechanizing the present statements would first expose these specification problems. Reference: §6.3 (ownership/ch-soundness.tex:86).

***

**1\.3. The thesis needs to distinguish two monotonicity claims; one currently conflicts with a displayed rule.**

**Claim.** Monotonicity of inference and monotonicity of accepted programs across compiler releases are separate obligations.

For inference, §4.6 orders callback effects by inclusion and supplies by:

\\\[
\\mathrm{owned}\\ \\sqsubset\\ \\mathrm{borrowed}.
\\\]

Now compare callbacks with the same result provenance:

```
keep xs = xs
grow xs = [ …xs, 1 ]
```

Adding `W` makes `grow` more pessimistic than `keep`. But §3.8’s `map` rule supplies the element **borrowed** when the callback does not consume it and **owned** when it does. Increasing the callback’s pessimism therefore makes this component more optimistic. The product order in §4.6 does not make this transfer monotone.

This does not establish unsoundness by itself. An iteration that explicitly joins each new result into the old state still ascends a finite lattice and terminates. What fails is the stated justification for a monotone transfer and its least, most permissive solution. Demands and supplied permissions need an order that accounts for their opposing roles.

The release-stability promise in §8.5 needs a different argument. Finer paths can introduce additional guard atoms or exceed a width cap, producing `⊤` where an older checker succeeded. “More precise” before widening does not guarantee a larger accepted set afterward. Fixing a false trusted row also necessarily breaks previously accepted programs; the thesis appropriately recognizes this exception.

**Confidence: high. Author action:** Reformulate conditional summaries as contracts with explicit requirements and guarantees, then prove their ordering. For release stability, require preservation of old valid derivations or an abstraction-simulation theorem, including caps. Describe stability as a compatibility policy with a soundness exception until that theorem exists. References: §§3.8, 4.6 (ownership/ch-inference.tex:176), 8.5.

***

**1\.4. Much of the trusted surface is an artifact of the implementation boundary, rather than irreducible trust.**

**Claim.** Section 6.5 correctly acknowledges the size of the trusted surface, but should separate primitive trust from missing proof machinery.

The genuinely unavoidable implementation boundary includes array allocation, reads and writes, view representation, builder hand-over, host retention, continuation behavior, and renderer/runtime entry points. These operations connect beni semantics to JavaScript.

By contrast, `map`, folds, `Dict.update`, and schema mappings are algorithms. Their ownership properties could follow from more fundamental contracts. Their current assertions compensate for limitations such as allocation-site merging and inability to express temporarily removing one element from a container.

A useful decomposition is:

- A traversal primitive establishes that successive elements occupy separated positions.
- A focus operation temporarily removes one position from the container’s usable contents.
- A builder accepts an element with stated ownership and separation evidence.
- Closing the builder derives the resulting container’s properties.

This would make “fresh callback results form an exclusive list” a theorem with explicit premises, exposing the missing premise in item 1.1.

The audit also calls rows “sound” while noting that complete rows have not yet been enumerated. For `Schema.decode`, knowing that mappings return owned still requires establishing that their inputs were supplied owned and sufficiently separated.

**Confidence: high. Author action:** Divide §6.5 into primitive contracts, derived library contracts, and temporary assertions. Give each temporary assertion a derivation obligation. Do not treat one pinned example as evidence for a universally quantified callback contract. Reference: §6.5 (ownership/ch-soundness.tex:420).

***

**1\.5. Ownership summaries are public API, including when ordinary types and value behavior remain unchanged.**

**Claim.** Interface hashing solves stale compilation, but it does not solve package compatibility.

For example, replacing:

```
prepare xs = List.copy xs
```

with:

```
prepare xs = xs
```

preserves the function’s ordinary type and structural result. It nevertheless breaks callers such as:

```
ys = prepare xs
zs = [ …ys, 9 ]
( zs, List.length xs )
```

The original result was fresh; the replacement aliases `xs`. A package ecosystem must treat that change as a contract change.

Compatibility involves more than “does it consume more?” It includes result aliases, escapes, callback invocation counts, ownership supplies, exclusivity requirements and guarantees, and opaque slots. Adding a possible result alias can be breaking without adding any write effect.

Under semantic versioning, incompatible changes to a declared public API require a major release. The language must therefore define published ownership guarantees as part of that API. [Semantic Versioning 2.0.0](<https://semver.org/>)

Opaque slots introduce another distinction: renumbering a private representation may change interface bytes without changing client capabilities. Conversely, an implementation change behind an opaque type can weaken a capability clients relied upon.

**Confidence: high. Author action:** Specify semantic compatibility between summaries, modulo slot and freshness-name renaming. Offer generated, frozen public contracts that implementations must satisfy, while retaining inference internally. Add a package-level compatibility report explaining which client capability was lost. References: §§4.10, 9.8, 10.4; §11.2, Changes 5 and 9.

***

**1\.6. Suspension is not intrinsically an ownership loss; transfer and retention are the difficult parts.**

**Claim.** The argument for a private list surviving suspension is plausible. The treatment of shared tasks is soundly conservative in intent but substantially imprecise.

Section 9.2 is right that a parked local can remain the same holder. If another fiber cannot reach the list, parking does not create an observer. One-shot continuation use prevents duplication of that execution.

But one-shotness alone is insufficient. The proof also needs:

- Finalizers to retain exactly their declared captures.
- Cancellation not to reactivate an old continuation.
- Reentrant dispatch to preserve the payload hand-over rules.
- Foreign callbacks to respect retention and call-count contracts.
- Runtime-retained results to remain shared even after the producing fiber finishes.

The thesis addresses these through A2, A6, A7, `Task.join = ⊤`, and the send protocol. These are meaningful protections, not omissions.

The precision loss is permanent escape: a scoped child that only reads a list can finish, yet the list remains escaped. Similarly, a child that is the sole owner of a freshly produced result cannot transfer it through ordinary multi-reader `join`.

**Confidence: medium on full soundness, high on the precision loss. Author action:** Separate “parked privately,” “transferred to a child,” “temporarily lent,” and “retained for multiple readers” in the formal account, even if the first implementation merges the last three. Add suspension and cancellation cases to the proof and evaluation. References: §§2.2, 6.6, 7.8, 9.2.

***

**1\.7. Histories expose a missing abstraction; splices expose a different problem.**

**Claim.** Rejecting an actual old-version observer is consistent with the settled rule. Treating every resulting difficulty as the unavoidable price of versions is too broad.

The first history copy in §7.14 preserves a real old version. The second copy on `Undo` compensates for losing the separation between the popped head and the remaining history. These are different costs: one pays for the requested semantics under this representation; the other pays for the abstraction.

Splices are different again. In:

```
List.take xs i ++ List.drop xs (i + 1)
```

the program may intend to keep only the result. The obstacle is simultaneous access through slices and possible identity reuse, not necessarily a lasting history. Named operations such as `removeAt` are a reasonable library answer.

There is also a concrete overstatement in proposal O2: dropping identity promises cannot generally remove sharing between a filtered list and its source. If a filter keeps every element and returns its input, the two lists really are aliased. A relational entry can exploit proof that this did not happen; it cannot establish unconditional disjointness while retaining that possibility.

For editors, undo and snapshots are ordinary application features. Calling their absence a niche restriction would narrow the thesis’s central population without saying so.

**Confidence: high. Author action:** Separate genuine version preservation, lost separation after moves, and slice overlap in both the argument and measurements. Provide an explicit persistent/versioned sequence option, and prioritize eliminating the second undo copy. References: §§5.4, 7.11, 7.14; §11.3, O2 and O4.

***

**1\.8. Report mode can answer a static corpus question, but only part of the user-experience question.**

**Claim.** The evaluation plan is materially stronger than a selective count of successful idioms, but its main denominator is insufficient by itself.

Sections 12.4–12.8 already address important biases: externally written Elm applications, all demand sites, per-application results, counted migration changes, and a programmer study. These should remain.

However, rejected demands divided by demands measures **static rejection density**. “Programmers almost never hit the error” also concerns how often an application fails to compile, how errors recur during development, and how expensive repairs are.

One captured model list can produce errors at many edit sites. Counting all of them measures disruption, but not independent causes. Conversely, a single rejection can force a substantial API redesign. Large applications can dominate the pooled denominator without representing a typical development experience.

The hand classification also calls some rejected programs “wrong had the write been in place.” That identifies an invalid compiler transformation, not necessarily a bug in a program written with value semantics.

**Confidence: high. Author action:** Retain the stated metric and add application acceptance, distinct root causes, repair iterations, changes outside the reported function, and explicit copies introduced by repairs. Freeze the raw port before repairs and report the repaired version separately. Include development tasks involving undo, asynchronous work, and nested data. References: §§12.3–12.8 (ownership/ch-evaluation.tex:99).

***

**1\.9. The differential plan targets interactions, but the oracle needs repair before it can judge them.**

**Claim.** The generator is appropriately motivated; the proposed sanitiser does not yet match the theorem’s exceptions.

Section 12.1 explicitly combines closures, callbacks, opaque types, recursion, sends, and release representations. That directly addresses the historical failure mode. The next improvement is to generate **heap-sharing structures**, not merely combinations of syntax: fresh outer containers with duplicated inner cells, closures sharing captures, and cells reachable through several abstract representatives.

There are two oracle problems.

First, A11 explicitly permits a stale identity comparison inside `map` after an owned callback edits and returns its element. Section 12.2 says every stale identity comparison traps. A valid intended use can therefore trip the proposed sanitiser.

Second, §6.2 says reading a field of a current record yields a current reference. That must not indiscriminately refresh a stored child reference’s stamp. Otherwise reading a stale nested alias through a current parent can erase precisely the evidence the sanitiser needs.

The central claim “no stale reference is ever used” consequently needs qualification, or the privileged algorithms need changing. Allowing a privileged stale comparison requires a semantic argument about both branches; merely listing both result provenances does not prove equivalent behavior.

**Confidence: high. Author action:** Define one executable observation policy shared by the proof and sanitiser. Preserve stamps on stored reference edges and narrowly specify permitted internal comparisons. Exercise multiple suspension schedules, callback invocations, dispatches, module boundaries, and release representations. Add deliberately broken rows and missing retention facts as negative controls, and use an independent value interpreter where practical. References: §§6.2, 6.4/A11, 12.1–12.2.

## 2\. Challenge the foundations

**2\.1. Give the analysis a declarative type-and-effect core; do not assume this requires sacrificing its precision.**

**Claim.** “Dataflow analysis versus type system” is a false architectural choice.

The thesis already has most ingredients of an inferred type-and-effect system: function contracts, directional constraints, result reachability, affinity, and conditional requirements. Calling them summaries does not eliminate questions about compositionality, admissible substitution, or best solutions.

The useful reformulation would be a judgment over the evaluation-order IR:

\\\[
\\Gamma;\\Omega \\vdash e:\\tau \\triangleright \\Omega';S
\\\]

Here, Ω describes currently usable ownership and separation facts, and S records reads, writes, escapes, and result reachability. The existing analysis would infer a derivation of this judgment.

A direct replacement with a simple occurrence-based uniqueness system could lose dead-alias recovery, per-field last use, and some callback precision. A flow-sensitive judgment need not lose them. The implementation can still run after ordinary type checking.

Clean and de Vries supply useful models for structural propagation and closure attribution, rather than an obligation to copy their entire inference design. Affe is further evidence that an ML-style type system can infer substantial affinity and borrowing information without requiring linearity annotations in expressions. [Affe: _Kindly Bent to Free Us_](<https://arxiv.org/abs/1908.09681>)

**Confidence: high on the architecture; medium on the eventual inference complexity. Author action:** Present a declarative core separately from its solver, and prove inference sound with respect to that core. Replace “flows avoid the principal-type problem” with a precise claim about the supported contract domain. References: §§3.6–3.11, 4.5–4.7, Chapter 13, Appendix B.1.

***

**2\.2. Share the semantic infrastructure of ownership and write sets, while keeping their guarantees distinct.**

**Claim.** One common description of operations would reduce risk; one undifferentiated analysis would obscure important differences.

Ownership asks whether an operation may reuse storage. Write sets ask which observations may change and which rendering actions follow. A fresh replacement can require rendering without consuming its input. An in-place operation can consume storage while leaving contents unchanged.

Section 9.4 already identifies the correct architectural boundary: general modular ownership checking, specialized message-level rendering analysis, and a shared entry-state computation. I would retain that distinction.

The unnecessary duplication is elsewhere: path interpretation, constructor erasure, library operation semantics, result provenance, and field access. If two tables independently describe `List.update`, their disagreement becomes a correctness risk.

A common operation contract could yield two projections: ownership requirements and change information. For the renderer, the conservative compatibility obligation is that every possible content change licensed by the operation is covered by its write set. This need not equate “consumed” with “visibly changed.”

**Confidence: high. Author action:** Share typed paths, representation mappings, and library contracts. Keep separate soundness statements and cross-check their projections. Preserve an independent testing oracle rather than deriving every check from the same table. References: §§6.3, 7.9/P7, 9.4 (ownership/ch-compiler.tex:43).

***

**2\.3. “Lists only” is a sensible first boundary, but most of the analysis is already about the whole reachable heap.**

**Claim.** Lists are a useful implementation scope, not a compelling final semantic boundary.

The checker already follows records, trees, dictionaries, opaque types, closures, and commands to find lists. Once closures are also modeled as cells, the abstract machinery is plainly more general than arrays.

Nevertheless, extending mutation is not free. Today a record of scalars crosses the ownership axis. If records themselves become mutable cells, it stops crossing. Aliases that previously needed no tracking become relevant, and record identity enters the renderer obligations. Mutating `Dict` nodes similarly changes the status of persistent structural sharing.

A more durable foundation is “which locations this operation may overwrite,” with lists as the first implementation. That permits ownership of one mutable field while other fields retain ordinary persistent sharing.

The direct platform’s separate ownership rule for records is an especially strong reason to generalize the _formal model_ before independently growing two ownership disciplines.

**Confidence: high. Author action:** Parameterize the formal core by mutable locations and operation footprints. Keep the initial implementation list-focused, then evaluate record mutation as an additional instantiation. Avoid promising that enabling it will preserve today’s crossing or acceptance behavior. References: §§3.1, 3.2, 9.7, 14.3.

***

**2\.4. The simpler alternative is fewer exceptional contracts and better APIs, not necessarily a less precise local analysis.**

**Claim.** The design’s complexity comes disproportionately from reconstructing ownership across abstractions and runtime protocols.

Removing per-path flow or liveness would sacrifice the precise cases that make Conduit and ordinary model updates work. Those mechanisms earn their complexity in §§5.3–5.5.

A simpler design worth comparing would retain those mechanisms but organize higher-order operations around a small number of verified traversal and update forms. `map`, folds, and focused updates would derive their contracts from these forms rather than receiving separate hand-written privileges. Commands would normally accept already computed values; event messages would normally carry identifiers.

An even smaller uniqueness discipline could be a useful experimental baseline. Its precision loss should be measured on the same external corpus, with each additional feature required to recover identifiable programs. It should not silently replace the full design before that comparison.

The thesis already proposes several relevant API changes, but treats them as extensions beside the checker. They are central to achieving the goal with manageable machinery.

**Confidence: medium. Author action:** Add a design comparison between the full checker, a small declarative core with derived traversal contracts, and the same core with ownership-friendly platform APIs. Assess repairs and conceptual burden as well as accepted sites. References: §§5.3, 7.8; §11.3/O5; Chapter 12.

## 3\. Novel directions

**3\.1. Make model hand-over a language-level capability rule, without claiming that one rule proves the entire runtime.**

**Proposal.** Treat each `update` as consuming the current model capability and producing its successor. Keep this implicit in ordinary beni syntax.

Conceptually:

update:(Msg,Model^{ω})→(Model^{ω'},Cmd Msg),

where the old model capability becomes unavailable when the successor is installed.

This would turn P1 into a checked invariant of a small TEA driver. `view` would receive a temporary reading capability; a command could not retain access to mutable model paths after that capability ended. Repeated mounts would receive independently created capabilities through `init`.

But an affine model handle does **not** establish internal separation:

```
{ a = xs, b = xs }
```

still contains two routes to one list. Nor does model consumption alone repair cached row items, stale markup handlers, or identity-based rendering skips. P3–P7 remain substantive obligations.

**Buys:** A clearer architectural guarantee and fewer informal runtime hand-over claims.

**Costs:** Restrictions on retaining model-derived values, plus a typed or verified driver boundary. Per-path ownership remains necessary inside the model.

The closest precedents are uniqueness-based state threading and encapsulated state; Launchbury and Peyton Jones use parametricity to prevent mutable state escaping its scope. [_Lazy Functional State Threads_](<https://launchbury.blog/wp-content/uploads/2019/01/lazy-functional-state-threads.pdf>)

**Confidence: medium. Author action:** Formalize a tiny TEA driver with this capability, then identify exactly which of P1–P7 become derivable. Reference: §7.9.

***

**3\.2. Treat a message as a permission epoch, not as a region whose entire storage dies at return.**

**Proposal.** Introduce an implicit dispatch region that tracks temporary allocations and access to the incoming model, while permitting surviving storage to transfer into the next model.

The naive proposal fails in two ways. An update routinely returns existing model fields, so their storage must survive. And fresh allocation does not imply unique reachability:

```
xs = [ 1 ]
{ a = xs, b = xs }
```

Both fields are fresh relative to the dispatch, yet alias each other.

A viable design distinguishes temporary data, data transferred into the successor model, and data exported to commands. Old _permissions_ expire at return; storage reachable from the new model remains. Nothing requires physically copying surviving arrays.

Tofte–Talpin regions provide prior art for inferred lifetimes and escape constraints, but region membership alone does not supply the separation property needed here. [Tofte and Talpin, _Region-Based Memory Management_](<https://www.sciencedirect.com/science/article/pii/S0890540196926139>)

**Buys:** A structured account of dispatch-local captures, fresh temporary builders, and values that may escape.

**Costs:** Region polymorphism or an equivalent internal representation, explicit treatment of commands, and careful promotion/transfer rules. JavaScript still performs physical memory management.

**Confidence: medium. Author action:** Explore permission epochs first, with no allocator changes. Prove that anything retained across an epoch boundary either transfers ownership or retains only permitted reading access. References: §§3.7, 7.8–7.9, 9.2.

***

**3\.3. Add witness-producing diagnostics, with three honest outcomes.**

**Proposal.** After rejecting an edit, search the relevant program slice for an execution that observes the old version.

The search should operate on both semantics. A stale read alone is weaker than an observable difference: a read can be masked, its result discarded, or the write can be a no-op.

There should be three outcomes:

| Search result | Diagnostic |
|---|---|
| Replayed execution produces different observations | “This input/event sequence demonstrates sharing.” |
| A stronger analysis proves the apparent conflict impossible | “The basic checker lost this separation”; accept only through the stronger proof |
| Search exhausts its budget or lacks an environment model | “Possible sharing; no witness found within these limits.” |

Failure to find a witness cannot establish that the program is safe or that the rejection is merely an analyzer defect. This matters for unbounded recursion, event sequences, and foreign behavior.

Section 8.4’s exact tags are useful provenance, but exact alias provenance alone does not prove feasible control flow or a changed observation. The relevant prior art is counterexample-guided abstraction refinement: abstract counterexamples must be checked against concrete behavior. [Ball, _Formalizing Counterexample-driven Refinement_](<https://www.microsoft.com/en-us/research/publication/formalizing-counterexample-driven-refinement-with-weakest-preconditions/>)

**Buys:** Explanations users can verify, and useful cases for improving the checker.

**Costs:** Search latency, environment models, and substantial infrastructure.

**Confidence: high on the distinction; medium on practical coverage. Author action:** Start with replayable witnesses for straight-line code and bounded message sequences. Keep rejection sound when the diagnostic search is inconclusive. References: §§8.1, 8.4, 12.1–12.2.

***

**3\.4. Offer an explicit versioned sequence, while distinguishing full persistence from semi-persistence.**

**Proposal.** Add an opt-in sequence type whose documented representation maintains versions through update logs or persistent nodes. Ordinary `List` retains the settled rule.

Baker-style rerooting can keep one version in a direct array and represent others through differences. Changing the current version requires traversing and reversing relevant differences; accessing alternating distant versions can therefore be expensive. This is an explicit cost model of the chosen type, not a fallback triggered by failed uniqueness. [Conchon and Filliâtre, _A Persistent Union-Find Data Structure_](<https://usr.lmf.cnrs.fr/~jcf/publis/puf-wml07.pdf>)

Semi-persistence is narrower: Conchon–Filliâtre allow access/update according to an ancestor discipline. After backtracking and branching, an abandoned sibling version is not generally still valid. That cannot satisfy an unrestricted “all old versions remain valid” history API. [_Semi-Persistent Data Structures_](<https://usr.lmf.cnrs.fr/~jcf/publis/spds-rr.pdf>)

Nested values are another obligation. Preserving an outer array does not preserve a nested ordinary list that later changes in place. Snapshots must retain ownership constraints on nested contents or use versioned/persistent contents too.

**Buys:** Histories, branching editors, and snapshots without forcing full list copies at every retained version.

**Costs:** A second sequence abstraction, version metadata, retention costs, and access costs dependent on version movement. Variable-length insertion needs its own representation argument.

**Confidence: high on feasibility and limitations; medium on fit. Author action:** Specify the history access discipline before choosing the representation. Compare a fully persistent vector, rerooted arrays, and a restricted backtracking type on paper first. References: §§7.14, 10.9; §11.3/O4.

***

**3\.5. Make the plain-word vocabulary describe observable contracts.**

**Proposal.** Standardize on **reads**, **consumes**, **keeps**, and **builds**, with explicit wording for where retained values go.

For example:

| Internal fact | User-facing wording |
|---|---|
| `R`, without retention | “Reads this list during the call.” |
| `W` | “Consumes this list; use the returned version afterward.” |
| Result provenance names an argument | “The result keeps this list.” |
| `E` | “Keeps this list after the call, for later work.” |
| Fresh result | “Builds a new list.” |

The distinction between “the result keeps it” and “later work keeps it” is essential. Combining both into an unexplained “keeps” would hide one of the thesis’s strongest precision choices.

A construction message should name the chosen base directly: “The first spread consumes `acc`.” A callback error should say “may call this function again,” rather than requiring users to learn affinity terminology.

Chapter 8 already moves strongly in this direction. The novel step is to use the same vocabulary in generated API documentation and package compatibility reports, so users can predict errors before encountering them.

**Buys:** A coherent mental model across errors, libraries, and interfaces.

**Costs:** Some technical distinctions need a second explanatory sentence rather than a single label.

**Confidence: high. Author action:** Test prediction as well as repair: ask users what each API permits, then compare their understanding with the inferred contract. References: §§3.7, 8.1–8.4, 12.7.

***

**3\.6. Replace global deep exclusivity with separation focused on the paths an operation writes.**

**Proposal.** Generalize `excl` into a small family of separation facts parameterized by the callback’s write paths.

Suppose each card has independently owned `notes`, but all cards share a read-only `labels` list:

```
List.map cards (λcard →
    { card | notes = [ …card.notes, note ] })
```

Section 3.11’s global condition can reject the container because the labels share. Yet the edit needs separation of `notes` from every other observable route to those notes. It does not require two read-only label paths to be separated from each other.

The appropriate condition is stronger than “notes are distinct across cards” but weaker than full exclusivity: every written cell must be separated from all other paths that may observe it; unrelated read-only cells may alias.

The same relational machinery could preserve:

model.todos ⊥ model.history\[\*\]

after moving a history head into `todos` and retaining only the tail. That targets the second undo copy without requiring unrestricted path-sensitive analysis.

**Buys:** More ordinary shared metadata, more useful nested updates, and better preservation of moves across TEA entry.

**Costs:** Relational facts, more involved joins, and a new summary abstraction. Separation logic and reachability systems offer the relevant vocabulary; the thesis already cites work expressing uniqueness through separation. [_Uniqueness is Separation_](<https://arxiv.org/abs/2602.06386>)

**Confidence: medium. Author action:** Start with separation facts required by actual write paths and container head/rest splits. Evaluate this before adopting a general relational heap domain. References: §§3.10–3.11, 7.4, 7.14.

***

**3\.7. Add a task result that can be taken once, alongside ordinary shared joins.**

**Proposal.** Provide an explicitly affine task handle for computations whose result can transfer to exactly one receiver.

Ordinary `Task.join` should retain its current conservative interpretation: the runtime can hand the same value to multiple joiners. A distinct handle could support a consuming `take`, with a contract that the runtime relinquishes its result reference.

This requires more than making the handle affine. The producer must return owned contents; a task returning a top-level list or a captured shared value does not become safe because there is only one receiver. Finalizers must not retain a conflicting observer either.

A related scoped API could restore a temporary read loan after all child readers have ended, provided no result, reference cell, or escaped callback carries that loan outward. That is a static structured-lifetime guarantee, rather than a test that some arbitrary task happens to be finished.

**Buys:** Useful asynchronous pipelines without copying merely because results passed through the task runtime.

**Costs:** An additional task abstraction and cancellation/cleanup rules. It also exposes a meaningful distinction that ordinary `join` intentionally hides.

Affinity, borrowing, and structured scopes supply prior art, including Affe’s inferred resource discipline. [_Kindly Bent to Free Us_](<https://arxiv.org/abs/1908.09681>)

**Confidence: medium. Author action:** Specify result transfer and cleanup semantics for one consuming task operation before attempting general escape recovery. References: §§2.2, 6.5, 7.8, 9.2.

***

**3\.8. Let inference produce checkable ownership evidence, not only a verdict.**

**Proposal.** Separate a sophisticated inference engine from a small validator for its ownership derivations.

For each accepted demand, evidence would establish known provenance, absence of conflicting retention, deadness of old holders, and required separation. Module summaries would be checked against bodies; library traversal contracts would reference reusable derivations.

This would permit improvements to inference without making every solver optimization part of the trusted core. It also provides a concrete interpretation of release stability: an older derivation remains acceptable when its assumptions and primitive contracts remain valid.

The validator must check more than the existing `reason` tags. A source span and a label explain a decision but do not prove it. Conversely, this need not place formal proofs in user code or shipped JavaScript.

The architecture resembles proof-carrying compilation, where the producer supplies evidence checked by a smaller trusted component. [Necula and Schneck, _Proof-Carrying Code with Untrusted Proof Rules_](<https://people.eecs.berkeley.edu/~necula/ISSS02/>)

**Buys:** A smaller trusted checker, better regression diagnosis, and a clean interface between precision improvements and the sound core.

**Costs:** An evidence language, validation work, and explicit handling of recursive invariants. Primitive JavaScript contracts and backend correctness remain separate obligations.

**Confidence: medium. Author action:** Begin with validation of summary contracts and exclusive-container derivations—the two areas where the present text most relies on informal assertions. References: §§4.4–4.7, 6.5, 8.4–8.5.

***

**Top three recommendations**

1. **Repair and formalize the ownership core before treating the current rows as settled.** Address the nested-freshness counterexample, the summary-order reversal, and the mismatch between permitted privileged comparisons and “no stale use.” **Confidence: high.**
2. **Make traversal contracts and model hand-over derivable from a small declarative system.** Keep inference and ordinary beni syntax, but reduce independent library assertions and make ownership compatibility part of package APIs. **Confidence: high on the need; medium on the exact design.**
3. **Evaluate programmer burden alongside static rejection density.** Preserve the external-corpus plan, add root-cause and repair measurements, and make histories, asynchronous transfer, and partially shared nested data explicit test populations. **Confidence: high.**

**Overall assessment.** The basis—strict evaluation, last-use ownership, explicit copies, modular reachability summaries, and rendering driven by write sets—is viable. The particular rule set is not sound as written, and the current proof does not yet establish its claimed result; the counterexample does not require abandoning the settled language decisions. The central goal looks achievable for code that repeatedly replaces one current model, especially with well-designed command and container APIs. Its achievement across a broad Elm-like application ecosystem remains unestablished. Reaching that broader goal will likely require a better account of separation and ownership transfer, plus an explicit abstraction for versions, rather than indefinitely adding exceptions to the present rules.
