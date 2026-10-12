import Ownership.Checker
import Ownership.HeapProof
import Ownership.Library

/-! # Soundness: the bridge between the checker and concrete heaps

This module states the theorems the thesis's argument needs (ch-soundness.tex
§6.3, with fifth-review clause 2 as repaired) over the executable checker and
the two interpreters of this project, and proves the parts that are within
reach. Every unproved statement is a named theorem whose proof is `sorry`;
COVERAGE.md lists them. No axiom is introduced.

Proved here:
* `cellOverlap_sound`, `demandProblem_sound`: the checker's cell tests, read
  through a separating naming of origins, exclude every shared array.
* `builder_alloc_describes`: the abstract builder value describes the concrete
  allocation, exclusive certificate included.
* `invariant_initial`, `invariant_observations`: the configuration invariant
  holds at the start and fixes every observation made so far.
* `accepted_traces_agree`: the main theorem, *derived* from the two named
  unproved lemmas `invariant_preserved` and `summary_sound`.

Unproved (`sorry`): `summary_sound` (Lemma 6.7, clauses 1–4, clause 2 as
repaired), `map_summary_sound` (map's derived row), `invariant_preserved`
(the step case of the prefix induction). -/

namespace Ownership.Soundness

open InPlaceSemantics HeapProof

/-! ## Naming origins by arrays -/

/-- Which heap arrays an origin may name. -/
abbrev Naming := Origin → List Nat

def named (γ : Naming) (cs : List Origin) (c : Nat) : Prop := ∃ o ∈ cs, c ∈ γ o

/-- The naming respects the checker's aliasing test: two origins the checker
    calls non-aliasing name disjoint arrays. This is what distinct parameter
    paths (checked Disjoint at the call), distinct sites and the two position
    tags of an exclusive traversal must provide; it is part of the invariant. -/
def Separating (γ : Naming) : Prop :=
  ∀ a b, aliases a b = false → ∀ c, c ∈ γ a → c ∉ γ b

theorem cellOverlap_false (as bs : List Origin) (h : cellOverlap as bs = false) :
    ∀ x ∈ as, ∀ y ∈ bs, aliases x y = false := by
  intro x hx y hy
  unfold cellOverlap at h
  have hx' := List.any_eq_false.mp h x hx
  simp only [Bool.not_eq_true] at hx'
  have hy' := List.any_eq_false.mp hx' y hy
  simpa using hy'

/-- The checker's overlap test, read through a separating naming, means that
    no array is named by both lists. -/
theorem cellOverlap_sound (γ : Naming) (hγ : Separating γ) (as bs : List Origin)
    (h : cellOverlap as bs = false) : ∀ c, named γ as c → ¬ named γ bs c := by
  intro c ⟨x, hx, hcx⟩ ⟨y, hy, hcy⟩
  exact hγ x y (cellOverlap_false as bs h x hx y hy) c hcx hcy

/-- A demand that passes (thesis §3.8's four side conditions) names only
    known, unshared cells, none named by a later holder, and — unless the
    Disjoint control is active — none named by another operand path. -/
theorem demandProblem_sound (γ : Naming) (hγ : Separating γ) (cfg : Config)
    (escapes cs later others : List Origin)
    (h : demandProblem cfg escapes cs later others = none) :
    (∀ o ∈ cs, known o = true ∧ unescaped o = true) ∧
    (∀ c, named γ cs c → ¬ named γ later c) ∧
    (cfg.has .disjoint = false → ∀ c, named γ cs c → ¬ named γ others c) := by
  unfold demandProblem at h
  split at h
  · exact absurd h (by simp)
  split at h
  · exact absurd h (by simp)
  split at h
  · exact absurd h (by simp)
  split at h
  · exact absurd h (by simp)
  split at h
  · exact absurd h (by simp)
  rename_i hk hu _ hdead hdisj
  refine ⟨?_, cellOverlap_sound γ hγ cs later (by simpa using hdead), ?_⟩
  · intro o ho
    simp only [Bool.not_eq_true', List.all_eq_false, not_exists, not_and] at hk hu
    exact ⟨by simpa using (List.all_eq_true.mp (by simpa using hk) o ho),
           by simpa using (List.all_eq_true.mp (by simpa using hu) o ho)⟩
  · intro hm
    simp only [hm, Bool.not_false, Bool.true_and] at hdisj
    exact cellOverlap_sound γ hγ cs others (by simpa using hdisj)

/-! ## Abstract values and concrete heaps -/

/-- Every array reachable from `v` is named by some cell of `a`. -/
def Covers (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  ∀ n o cs, Represents heap n v o cs → ∀ c ∈ cs, named γ a.cells c

/-- An exclusive certificate means the value's footprint repeats no array. -/
def CertifiedExclusive (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  a.deepExclusive = true → ∀ n o cs, Represents heap n v o cs → cs.Nodup

/-- `a` describes `v`: it names its footprint and its certificate holds. -/
def Describes (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  Covers γ heap a v ∧ CertifiedExclusive heap a v

theorem represents_empty_ref (h : Represents heap n (.ref c) o cs)
    (lookup : heap[c]? = some []) : cs = [c] := by
  cases h with
  | ref l hs =>
    rw [lookup] at l
    cases l
    cases hs
    rfl

/-- The abstract builder value describes the concrete allocation (§3.11,
    `primitive (.builder t)` against `prim (.builder t)`). -/
theorem builder_alloc_describes (γ : Naming) (s : State) (site : List Nat)
    (hsite : s.heap.size ∈ γ (.site site 0)) :
    ∃ s', (prim (.builder t) []).run s = .ok (.ref s.heap.size, s') ∧
      Describes γ s'.heap (.list [.site site 0] .bottom true) (.ref s.heap.size) := by
  refine ⟨{s with heap := s.heap.push []}, rfl, ?_, ?_⟩
  · intro n o cs h c hc
    have lookup : (s.heap.push [])[s.heap.size]? = some [] := by simp
    rw [represents_empty_ref h lookup] at hc
    simp at hc
    subst hc
    exact ⟨.site site 0, by simp [Abstract.cells, Abstract.paths, union], hsite⟩
  · intro _ n o cs h
    have lookup : (s.heap.push [])[s.heap.size]? = some [] := by simp
    rw [represents_empty_ref h lookup]
    simp

/-! ## Summary soundness (Lemma 6.7) -/

/-- The arrays reachable from `v` at path `p`: the root array at `[]`, every
    element's arrays at `.element`, a field's at `.field i`. Fuel bounds the
    walk (cyclic heaps are not built by the interpreters). -/
def pathCells (heap : Heap) : Nat → Value → Path → List Nat
  | 0, _, _ => []
  | _ + 1, .ref c, [] => [c]
  | n + 1, .ref c, .element :: rest =>
    ((heap[c]?).getD []).flatMap fun x => pathCells heap n x rest
  | n + 1, .record xs, .field i :: rest => (xs[i]?.map fun x => pathCells heap n x rest).getD []
  | n + 1, .closure _ caps, .capture i :: rest => (caps[i]?.map fun x => pathCells heap n x rest).getD []
  | n + 1, .closure _ caps, .env :: _ => caps.flatMap fun x => pathCells heap n x []
  | _, _, _ => []

/-- References a value holds directly (through records and closure captures,
    not through arrays). -/
def valueRefs : Value → List Nat
  | .ref c => [c]
  | .record xs => xs.attach.flatMap fun x => valueRefs x.val
  | .closure _ xs => xs.attach.flatMap fun x => valueRefs x.val
  | .int _ => []
termination_by v => sizeOf v
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem x.property
  all_goals omega

/-- A holder of an array: another array whose contents refer to it, or the
    program-lifetime observer (`shared`). Locals of a finished frame are gone. -/
inductive Holder where
  | array (d : Nat)
  | kept
  deriving BEq, Repr

def Holds (s : State) (h : Holder) (c : Nat) : Prop :=
  match h with
  | .array d => ∃ xs, s.heap[d]? = some xs ∧ ∃ x ∈ xs, c ∈ valueRefs x
  | .kept => ∃ x ∈ s.kept.toList, c ∈ valueRefs x

/-- The paths of an argument named in the summary's rows. -/
def rowAt (rows : List Origin) (i : Nat) (q : Path) : Bool :=
  rows.any (·.base == .parameter i q)

/-- Lemma 6.7 for one evaluated call of a declaration whose published summary
    is `s`, with argument values `args`, from state `pre` to `post` with
    result `r`. Clause 2 is the fifth reading's repair: the call creates no
    *new* holder of an argument cell that outlives it unless `E` is published;
    holders that existed before the call are not the call's to report. -/
structure CallSound (s : Summary) (args : List Value) (pre post : State) (r : Value) : Prop where
  /-- 1. An argument array changed by the call is at a `W` path. -/
  writes : ∀ i q c, c ∈ pathCells pre.heap 64 (args[i]?.getD (.int 0)) q →
    post.heap[c]? ≠ pre.heap[c]? → rowAt (s.writes ++ s.consumes) i q = true
  /-- 2 (repaired). Every holder of an argument cell after the call either
      held it before, or is an array of the result's footprint at a path
      whose `res` names the argument path, or the cell's path escapes. -/
  noNewHolders : ∀ i q c h, c ∈ pathCells pre.heap 64 (args[i]?.getD (.int 0)) q →
    rowAt s.escapes i q = false → Holds post h c →
    Holds pre h c ∨ ∃ d q', h = .array d ∧ d ∈ pathCells post.heap 64 r q' ∧
      (s.result.cellsAt q').contains (.parameter i q) = true
  /-- 3. A result array is an argument array its `res` names, or a fresh one
      (allocated during the call, so absent from `pre`). -/
  result : ∀ q c, c ∈ pathCells post.heap 64 r q →
    c ≥ pre.heap.size ∨ ∃ i p, c ∈ pathCells pre.heap 64 (args[i]?.getD (.int 0)) p ∧
      (s.result.cellsAt q).contains (.parameter i p) = true
  -- Clause 4 (calls, supply, xres, xreq) is not stated: the interpreters do
  -- not record callback invocations, so there is nothing to state it over.

/-- The concrete call of declaration `id` with closure captures `caps`. -/
def callResult (ds : List Decl) (id : Nat) (args caps : List Value) (fuel : Nat) (pre : State) :
    Except String (Value × State) :=
  match ds[id]? with
  | some d => (eval fuel ds (some (id, caps)) (bindArgs (args ++ caps)) d.body).run pre
  | none => .error "no declaration"

/-- **Summary soundness** (Lemma 6.7). For every accepted program and every
    summary it published, every concrete call of that declaration whose
    arguments the summary's inputs describe (exclusivity certificates and the
    owned paths unique at the call) satisfies the four clauses. Unproved: it
    needs the configuration invariant below for the callee's own frame and the
    induction over earlier calls in the prefix. -/
theorem summary_sound (p : Program) (a : Accepted) (ok : check p = .ok a)
    (e : CacheEntry) (he : e ∈ a.cache.toList) (args caps : List Value) (pre post : State)
    (r : Value) (fuel : Nat) (γ : Naming) (hγ : Separating γ)
    (described : ∀ i : Nat, Describes γ pre.heap (e.inputs[i]?.getD .bottom) ((args ++ caps)[i]?.getD (.int 0)))
    (run : callResult p.declarations e.decl args caps fuel pre = .ok (r, post)) :
    CallSound e.summary args pre post r := by
  sorry

/-- **Map's derived summary is sound.** `Library.map` is an ordinary
    declaration; this is `summary_sound` at its summaries, stated separately
    because it is the row T59 lived in: if map's published result is
    exclusive, the concrete result's footprint repeats no array. Unproved. -/
theorem map_summary_sound (a b : Ty) (p : Program) (acc : Accepted) (ok : check p = .ok acc)
    (e : CacheEntry) (he : e ∈ acc.cache.toList)
    (isMap : p.declarations[e.decl]? = some (Library.map a b))
    (args caps : List Value) (pre post : State) (r : Value) (fuel : Nat) (γ : Naming)
    (hγ : Separating γ)
    (described : ∀ i : Nat, Describes γ pre.heap (e.inputs[i]?.getD .bottom) ((args ++ caps)[i]?.getD (.int 0)))
    (run : callResult p.declarations e.decl args caps fuel pre = .ok (r, post)) :
    CallSound e.summary args pre post r ∧ CertifiedExclusive post.heap e.summary.result r := by
  sorry

/-! ## The main theorem, over execution prefixes -/

/-- Relates a value-semantics value to an in-place value in a heap: the value
    the array currently holds, at every depth (Lemma 6.1's correspondence for
    current references). -/
def Corresponds (heap : Heap) (v : Observation) (w : Value) : Prop :=
  snapshot heap 256 w = .ok v

/-- The configuration invariant of the prefix induction (§6.3, the gap the
    fifth reading named): the observations made so far are equal; every
    value-semantics binding corresponds to its in-place binding in the current
    heap; and the abstract environment describes the in-place one under a
    separating naming. `env` pairs each variable's two values. -/
structure Invariant (vs : ValueSemantics.State) (hs : InPlaceSemantics.State)
    (env : List (Var × Observation × Value)) (aenv : Env Abstract) (γ : Naming) : Prop where
  reads : vs.reads = hs.reads
  external : vs.externalReads = hs.externalReads
  fuel : vs.fuel = hs.fuel
  bindings : ∀ x o w, (x, o, w) ∈ env → Corresponds hs.heap o w
  separating : Separating γ
  described : ∀ x o w a, (x, o, w) ∈ env → aenv.lookup x = some a → Describes γ hs.heap a w

theorem invariant_initial (fuel : Nat) (γ : Naming) (hγ : Separating γ) :
    Invariant { fuel } { fuel } [] [] γ :=
  { reads := rfl, external := rfl, fuel := rfl
    bindings := by simp, separating := hγ, described := by simp }

/-- What the invariant buys at the end: the two traces' observation streams
    so far are the same. -/
theorem invariant_observations (h : Invariant vs hs env aenv γ) :
    vs.reads.toList = hs.reads.toList ∧ vs.externalReads.toList = hs.externalReads.toList :=
  ⟨by rw [h.reads], by rw [h.external]⟩

def valueEnv (env : List (Var × Observation × Value)) : Env Observation := env.map fun (x, o, _) => (x, o)
def heapEnv (env : List (Var × Observation × Value)) : Env Value := env.map fun (x, _, w) => (x, w)

/-- **The step case.** Evaluating an expression the checker accepted in the
    abstract environment `aenv`, from configurations related by the invariant,
    yields related configurations and corresponding results, or both
    evaluations fail. This is the simultaneous preservation over the whole
    configuration that the thesis says it has not written (§6.3), and the
    place `summary_sound` and Lemmas 6.2–6.6 are used. It quantifies over the
    expression, the environments and the enclosing function (`self`), so the
    induction covers calls that never return: they exhaust the shared fuel at
    the same tick in both interpreters. Unproved. -/
theorem invariant_preserved (ds : List Decl) (ctx : Context) (aenv : Env Abstract) (e : Expr)
    (after : Live) (site : List Nat) (st st' : St) (r : Abstract)
    (accepts : (inferExpr ctx.config.inferenceFuel ctx aenv e after site).run st = .ok (r, st'))
    (fuel : Nat) (selfV : Option (Nat × List Observation)) (selfH : Option (Nat × List Value))
    (env : List (Var × Observation × Value)) (γ : Naming)
    (vs : ValueSemantics.State) (hs : InPlaceSemantics.State) (h : Invariant vs hs env aenv γ) :
    (∀ v vs', (ValueSemantics.eval fuel ds selfV (valueEnv env) e).run vs = .ok (v, vs') →
      ∃ w hs' γ', (InPlaceSemantics.eval fuel ds selfH (heapEnv env) e).run hs = .ok (w, hs') ∧
        Invariant vs' hs' env aenv γ' ∧ Corresponds hs'.heap v w ∧ Describes γ' hs'.heap r w) ∧
    (∀ msg, (ValueSemantics.eval fuel ds selfV (valueEnv env) e).run vs = .error msg →
      ∃ msg', (InPlaceSemantics.eval fuel ds selfH (heapEnv env) e).run hs = .error msg') := by
  sorry

/-- **Main theorem** (Theorem 6.1 for this core). For an accepted program and
    every fuel bound — every execution prefix, since both interpreters spend
    fuel identically — a successful value run is matched by a successful
    in-place run with the same trace: final value, every read, and every
    external observer read. Derived from `invariant_preserved` at the main
    expression; it inherits that lemma's gap and nothing else. -/
theorem accepted_traces_agree (p : Program) (ctx : Context) (r : Abstract) (st' : St)
    (accepts : (inferExpr ctx.config.inferenceFuel ctx [] p.main [] []).run {} = .ok (r, st'))
    (fuel : Nat) (t : Trace) (ht : ValueSemantics.run p fuel = .ok t) :
    ∃ t', InPlaceSemantics.run p fuel = .ok t' ∧ t.reads = t'.reads ∧
      t.externalReads = t'.externalReads ∧ t.finalValue = t'.finalValue := by
  have inv : Invariant { fuel } { fuel } [] [] (fun _ => []) :=
    invariant_initial fuel (fun _ => []) (by intro _ _ _ _ h; simp at h)
  have step := (invariant_preserved p.declarations ctx [] p.main [] [] {} st' r accepts fuel none none
    [] (fun _ => []) { fuel } { fuel } inv).1
  unfold ValueSemantics.run at ht
  cases hv : (ValueSemantics.eval fuel p.declarations none [] p.main).run { fuel } with
  | error msg => simp [hv] at ht; cases ht
  | ok res =>
    obtain ⟨v, vs'⟩ := res
    rw [hv] at ht
    obtain ⟨w, hs', γ', hrun, inv', corr, _⟩ := step v vs' hv
    simp only [bind, Except.bind, pure, Except.pure] at ht
    cases ht
    refine ⟨{ reads := hs'.reads.toList, finalValue := v, externalReads := hs'.externalReads.toList },
      ?_, by simp [inv'.reads], by simp [inv'.external], rfl⟩
    unfold InPlaceSemantics.run
    unfold Corresponds at corr
    simp only [heapEnv, List.map_nil] at hrun
    simp [bind, Except.bind, hrun, corr, pure, Except.pure]

end Ownership.Soundness

