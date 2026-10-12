import Ownership.Checker
import Ownership.HeapProof
import Ownership.Library

/-! # Soundness: the bridge between the checker and concrete heaps

This module states the theorems the thesis's argument needs (ch-soundness.tex
§6.3, with fifth-review clause 2 as repaired) over the executable checker and
the two interpreters of this project, and proves the parts that are within
reach. Every unproved statement is a named theorem whose proof is `sorry`;
COVERAGE.md lists them, with the reason each is believed true and the
falsification attempts made against it (`ownership falsify`). No axiom is
introduced. All statements are about programs the *corrected* checker accepts
(`check p = .ok _`, default config).

Proved, but **conditional on a naming** (`Separating γ`, or `hsite` for the
builder), which the unproved step lemma would have to construct:
* `cellOverlap_sound`, `demandProblem_sound`: the checker's cell tests, read
  through a separating naming of origins, exclude every shared array.
* `builder_alloc_describes`: given that the naming names the new array, the
  abstract builder value describes the concrete allocation.

Proved outright (bookkeeping): `invariant_initial`, `invariant_observations`,
`check_accepts_main`, `corrected_default`, and `old_invariant_counterexample`
(the review's counterexample is excluded by the restated invariant).

Proved **conditionally** on `invariant_preserved`: `accepted_traces_agree`, the
main theorem; it adds only bookkeeping to that lemma.

Unproved (`sorry`): `summary_sound` (Lemma 6.7 clauses 1–3, clause 2 as
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
    tags of an exclusive traversal must provide; it is part of the invariant.
    `unknown` (⊤) aliases only itself here, as in `aliases`: an array named by
    ⊤ is named by nothing else. -/
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

/-! ## Paths in a concrete heap

`AtPath heap v q w`: the value `w` is found at path `q` of `v`. A list path
step `element` reaches every item of the array as it is in `heap` now; a
function value's `env` step reaches every value its captures reach (the
summary layer's `π_i.env` stands for all of them). Unbounded and relational:
no fuel, so no depth at which a claim silently stops. -/

/-- `v` reaches `w` through arrays, records and closure captures. -/
inductive Reaches (heap : Heap) : Value → Value → Prop where
  | refl (v : Value) : Reaches heap v v
  | element {c : Nat} {xs : List Value} {x w : Value} :
      heap[c]? = some xs → x ∈ xs → Reaches heap x w → Reaches heap (.ref c) w
  | field {xs : List Value} {x w : Value} : x ∈ xs → Reaches heap x w → Reaches heap (.record xs) w
  | capture {d : Nat} {caps : List Value} {x w : Value} :
      x ∈ caps → Reaches heap x w → Reaches heap (.closure d caps) w

inductive AtPath (heap : Heap) : Value → Path → Value → Prop where
  | here (v : Value) : AtPath heap v [] v
  | element {c : Nat} {xs : List Value} {x : Value} {q : Path} {w : Value} :
      heap[c]? = some xs → x ∈ xs → AtPath heap x q w → AtPath heap (.ref c) (.element :: q) w
  | field {xs : List Value} {i : Nat} {x : Value} {q : Path} {w : Value} :
      xs[i]? = some x → AtPath heap x q w → AtPath heap (.record xs) (.field i :: q) w
  | capture {d : Nat} {caps : List Value} {i : Nat} {x : Value} {q : Path} {w : Value} :
      caps[i]? = some x → AtPath heap x q w → AtPath heap (.closure d caps) (.capture i :: q) w
  | env {d : Nat} {caps : List Value} {x w : Value} :
      x ∈ caps → Reaches heap x w → AtPath heap (.closure d caps) [.env] w

/-- The array `c` is at path `q` of `v`. -/
def ArrayAt (heap : Heap) (v : Value) (q : Path) (c : Nat) : Prop := AtPath heap v q (.ref c)

/-- Paths through records and closure captures only: the arrays at such a
    path of a value never change, since records and closures are immutable. -/
def immutablePath (q : Path) : Bool :=
  q.all fun s => match s with | .field _ | .capture _ => true | _ => false

/-! ## Abstract values and concrete heaps -/

/-- The cells an abstract value names at a path. A path ending in `env`
    names every cell the environment of the function value above it holds
    (`envCells`): for a symbolic input that is its `[env]` row, for a known
    function value the cells of all its alternatives' captures. -/
def namesAt (a : Abstract) (q : Path) : List Origin :=
  match q.getLast? with
  | some .env => (a.atPath q.dropLast).envCells
  | _ => a.cellsAt q

/-- Path by path, every array of `v` is named by a cell `a` has at that
    path. (Naming the footprint only as a whole is not enough: the Dead and
    Disjoint tests compare the cells of particular paths.) -/
def Covers (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  ∀ q c, ArrayAt heap v q c → named γ (namesAt a q) c

/-- An exclusive list in `a` certifies the concrete value at its path: that
    value's footprint (with multiplicity) repeats no array. -/
def CertifiedExclusive (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  ∀ q cs e w, a.atPath q = .list cs e true → AtPath heap v q w →
    ∀ n o fp, Represents heap n w o fp → fp.Nodup

/-- `a` describes `v`: it names its arrays path by path and its exclusivity
    certificates hold. -/
def DescribesShallow (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  Covers γ heap a v ∧ CertifiedExclusive heap a v

/-- A concrete closure is one of the alternatives of an abstract function
    value — the same declaration — its captures described by that
    alternative's (their arrays named, their certificates holding). -/
def DescribesClosure (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  match a, v with
  | .function _ alts, .closure id caps => ∃ capsAbs, (id, capsAbs) ∈ alts ∧
      capsAbs.length = caps.length ∧
      ∀ k : Nat, DescribesShallow γ heap (capsAbs[k]?.getD .bottom) (caps[k]?.getD (.int 0))
  -- A symbolic input stands for any closure of its type; what it may do is
  -- fixed by the guards a summary records (`GuardsHold`), not here.
  | .symbolic .., .closure _ _ => True
  | _, _ => False

/-- Paths through record fields and list elements: where an abstract value
    has the shape of the concrete one (`atPath` of a capture step is only a
    merge of cells). -/
def shapePath (q : Path) : Bool :=
  q.all fun s => match s with | .field _ | .element => true | _ => false

/-- Every closure found at a field or element path is one the abstract
    value at that path lists, with its own declaration (fourth review, P7: a
    closure of `capPush`, which writes its capture, described as one of
    `capGet`, which does not, made the step lemma false). -/
def ClosuresDescribed (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  ∀ q id caps, shapePath q = true → AtPath heap v q (.closure id caps) →
    DescribesClosure γ heap (a.atPath q) (.closure id caps)

/-- `a` describes `v`: arrays named path by path, certificates holding, and
    every closure at a field or element path one of `a`'s alternatives there. -/
def Describes (γ : Naming) (heap : Heap) (a : Abstract) (v : Value) : Prop :=
  DescribesShallow γ heap a v ∧ ClosuresDescribed γ heap a v

theorem represents_empty_ref (h : Represents heap n (.ref c) o cs)
    (lookup : heap[c]? = some []) : cs = [c] := by
  cases h with
  | ref l hs =>
    rw [lookup] at l
    cases l
    cases hs
    rfl

/-- In a heap where `c` is empty, the only value at any path of `.ref c` is
    `.ref c` itself, at the empty path. -/
theorem atPath_empty_ref (lookup : heap[c]? = some []) (h : AtPath heap (.ref c) q w) :
    q = [] ∧ w = .ref c := by
  cases h with
  | here => exact ⟨rfl, rfl⟩
  | element l mem _ =>
    rw [lookup] at l
    cases l
    simp at mem

/-- The abstract builder value describes the concrete allocation (§3.11,
    `primitive (.builder t)` against `prim (.builder t)`). -/
theorem builder_alloc_describes (γ : Naming) (s : State) (site : List Nat)
    (hsite : s.heap.size ∈ γ (.site site 0)) :
    ∃ s', (prim (.builder t) []).run s = .ok (.ref s.heap.size, s') ∧
      Describes γ s'.heap (.list [.site site 0] .bottom true) (.ref s.heap.size) := by
  have lookup : (s.heap.push [])[s.heap.size]? = some [] := by simp
  refine ⟨{s with heap := s.heap.push []}, rfl, ⟨?_, ?_⟩, ?_⟩
  · intro q c h
    obtain ⟨hq, hc⟩ := atPath_empty_ref lookup h
    subst hq
    cases hc
    exact ⟨.site site 0, by simp [namesAt, Abstract.cellsAt, Abstract.paths, union], hsite⟩
  · intro q cs e w _ h n o fp hr
    obtain ⟨_, hw⟩ := atPath_empty_ref lookup h
    subst hw
    rw [represents_empty_ref hr lookup]
    simp
  · intro q id caps _ h
    obtain ⟨_, hw⟩ := atPath_empty_ref lookup h
    cases hw

/-! ## Summary soundness (Lemma 6.7) -/

/-- The origin a summary uses for input `i` (arguments first, then captures)
    at path `p`. -/
def inputOrigin (nargs i : Nat) (p : Path) : Origin :=
  if i < nargs then .parameter i p else .capture (i - nargs) p

/-- A summary row names the input path. -/
def rowHas (rows : List Origin) (o : Origin) : Bool := rows.any (·.base == o)

/-- `q` is a path the canonical input `i` names: the rows speak only about
    these (a function-typed input has exactly `[]` and `[env]`). -/
def canonicalPath (ins : List Abstract) (i : Nat) (q : Path) : Prop :=
  q ∈ (ins[i]?.getD .bottom).paths.map Prod.fst

/-- A program-lifetime observer (`shared`) reaches the array `c`. -/
def keptReaches (s : State) (c : Nat) : Prop := ∃ k ∈ s.kept.toList, Reaches s.heap k (.ref c)

/-- Lemma 6.7 for one evaluated call of a declaration whose published summary
    is `s`, with canonical inputs `ins`, actual inputs `inputs` (the `nargs`
    arguments, then the captures), from state `pre` to `post` with result `r`.

    Clause 2 is the fifth reading's repair, made precise: the holders of an
    input array that outlive the call are the result and the program-lifetime
    observers. Clause 3 names every array of the result, so a result holder
    is accounted for there; clause 2 is the observers. Holders the call
    creates elsewhere are either garbage, or reachable only through an input
    array the call writes, which the caller's Dead check has made
    unobservable (a live holder of an array above a written path has the
    written cells among its own). -/
structure CallSound (s : Summary) (ins : List Abstract) (inputs : List Value) (nargs : Nat)
    (pre post : State) (r : Value) : Prop where
  /-- 1. An input array changed by the call is at a `W` path. -/
  writes : ∀ i q c, canonicalPath ins i q → ArrayAt pre.heap (inputs[i]?.getD (.int 0)) q c →
    post.heap[c]? ≠ pre.heap[c]? → rowHas (s.writes ++ s.consumes) (inputOrigin nargs i q) = true
  /-- 2 (repaired). A permanent observer reaches an input array after the
      call only if it did before, or the path escapes (`E`). -/
  noNewHolders : ∀ i q c, canonicalPath ins i q → ArrayAt pre.heap (inputs[i]?.getD (.int 0)) q c →
    rowHas s.escapes (inputOrigin nargs i q) = false → keptReaches post c → keptReaches pre c
  /-- 3. An array at path `q` of the result is fresh (allocated during the
      call), an input array at a path that `res(q)` names, or `res(q)` admits
      a shared or unknown cell. -/
  result : ∀ q c, ArrayAt post.heap r q c → c ≥ pre.heap.size ∨
    (∃ i p, canonicalPath ins i p ∧ ArrayAt pre.heap (inputs[i]?.getD (.int 0)) p c ∧
      (namesAt s.result q).any (·.base == inputOrigin nargs i p) = true) ∨
    (namesAt s.result q).any (fun o => o == .shared || o == .unknown) = true
  -- Clause 4 (calls, supply, xres, xreq) is not stated: the interpreters do
  -- not record callback invocations, so there is nothing to state it over.

/-- The concrete call of declaration `id` with closure captures `caps`. -/
def callResult (ds : List Decl) (id : Nat) (args caps : List Value) (fuel : Nat) (pre : State) :
    Except String (Value × State) :=
  match ds[id]? with
  | some d => (eval fuel ds (some (id, caps)) (bindArgs (args ++ caps)) d.body).run pre
  | none => .error "no declaration"

/-- The configuration the theorems speak about: the checker as published, with
    no deliberate hole, no historical old rule and not the per-call checker.
    Under any other configuration the controls show the theorems are false. -/
def Corrected (c : Config) : Prop :=
  c.mutant = none ∧ c.oldFreshRule = false ∧ c.dropTraversalEscapes = false ∧ c.reinfer = false

theorem corrected_default : Corrected ({} : Config) := ⟨rfl, rfl, rfl, rfl⟩

/-- A holder of an array: another array whose contents refer to it, or the
    program-lifetime observer (`shared`). Locals of a finished frame are gone. -/
inductive Holder where
  | array (d : Nat)
  | kept
  deriving BEq, Repr

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

def Holds (s : State) (h : Holder) (c : Nat) : Prop :=
  match h with
  | .array d => ∃ xs, s.heap[d]? = some xs ∧ ∃ x ∈ xs, c ∈ valueRefs x
  | .kept => ∃ x ∈ s.kept.toList, c ∈ valueRefs x

/-- An array is held, at the call, only by arrays of the call's own inputs:
    no other array and no program-lifetime observer. (Live locals of the
    caller are not heap holders; their absence is the caller's Dead check.) -/
def HeldOnlyByInputs (pre : State) (inputs : List Value) (c : Nat) : Prop :=
  ∀ h, Holds pre h c → ∃ (d i : Nat) (q : Path), h = .array d ∧ ArrayAt pre.heap (inputs[i]?.getD (.int 0)) q d

/-- The guards of a summary answer, for the function values `fs` a call
    passes (slot ↦ abstract closure), exactly as recorded. This is the
    condition under which the checker reuses the summary at a call (§3.7's
    guarded value resolved at the call); without it the summary's rows speak
    about other callbacks. -/
def GuardsHold (decls : List Decl) (config : Config) (s : Summary) (fs : List (Nat × Abstract)) : Prop :=
  ∀ g ∈ s.guards, ∃ st, (answer config.inferenceFuel decls config [{ actuals := fs }] g.query).run {} =
    .ok (g.answer, st)

/-- **Summary soundness** (Lemma 6.7). For every program accepted by the
    corrected checker and every summary it published, every concrete call of
    that declaration whose inputs the summary's canonical inputs describe
    (`described`: arrays named path by path under a separating naming,
    exclusivity certificates hold), whose function-typed inputs are closures
    resolving the summary's guards as recorded (`classes`), and whose owned
    input paths are unique at the call (`unique`: held by no array outside the
    inputs and by no permanent observer) satisfies clauses 1–3.
    Because the naming separates distinct canonical origins, a call that
    passes one array at two input paths is outside this statement (it is
    vacuous there); the caller's Disjoint test is what makes such a call safe
    when one of the paths is written. Unproved: it needs the configuration
    invariant for the callee's own frame and the induction over earlier
    calls in the prefix. -/
theorem summary_sound (p : Program) (a : Accepted) (ok : check p = .ok a)
    (e : CacheEntry) (he : e ∈ a.cache.toList) (args caps : List Value) (pre post : State)
    (r : Value) (fuel : Nat) (γ : Naming) (hγ : Separating γ)
    (described : ∀ i : Nat, Describes γ pre.heap (e.inputs[i]?.getD .bottom) ((args ++ caps)[i]?.getD (.int 0)))
    (fs : List (Nat × Abstract))
    (classes : GuardsHold p.declarations {} e.summary fs ∧
      ∀ j f, fs.lookup j = some f → DescribesClosure γ pre.heap f ((args ++ caps)[j]?.getD (.int 0)))
    (unique : ∀ o ∈ e.owned, ∀ c ∈ γ o, HeldOnlyByInputs pre (args ++ caps) c)
    (run : callResult p.declarations e.decl args caps fuel pre = .ok (r, post)) :
    CallSound e.summary e.inputs (args ++ caps) args.length pre post r := by
  sorry

/-- **Map's derived summary is sound.** `Library.map` is an ordinary
    declaration; this is `summary_sound` at its summaries plus the certificate,
    stated separately because it is the row T59 lived in: where map's published
    result is exclusive at a path, the concrete value there repeats no array.
    Unproved. -/
theorem map_summary_sound (a b : Ty) (p : Program) (acc : Accepted) (ok : check p = .ok acc)
    (e : CacheEntry) (he : e ∈ acc.cache.toList)
    (isMap : p.declarations[e.decl]? = some (Library.map a b))
    (args caps : List Value) (pre post : State) (r : Value) (fuel : Nat) (γ : Naming)
    (hγ : Separating γ)
    (described : ∀ i : Nat, Describes γ pre.heap (e.inputs[i]?.getD .bottom) ((args ++ caps)[i]?.getD (.int 0)))
    (fs : List (Nat × Abstract))
    (classes : GuardsHold p.declarations {} e.summary fs ∧
      ∀ j f, fs.lookup j = some f → DescribesClosure γ pre.heap f ((args ++ caps)[j]?.getD (.int 0)))
    (unique : ∀ o ∈ e.owned, ∀ c ∈ γ o, HeldOnlyByInputs pre (args ++ caps) c)
    (run : callResult p.declarations e.decl args caps fuel pre = .ok (r, post)) :
    CallSound e.summary e.inputs (args ++ caps) args.length pre post r ∧
      CertifiedExclusive post.heap e.summary.result r := by
  sorry

/-! ## The main theorem, over execution prefixes -/

/-- Relates a value-semantics value to an in-place value in a heap: the
    in-place value, read with enough fuel, is the value (Lemma 6.1's
    correspondence for current references). No fixed depth: a value one level
    deeper than any bound is still related; only observing it fails, in both
    interpreters alike (`observationDepth`). -/
def Corresponds (heap : Heap) (v : Observation) (w : Value) : Prop :=
  ∀ n, v.depth ≤ n → snapshot heap n w = .ok v

/-- Field projections of a live use (`atomUses` paths are field paths). -/
def projectObs : Observation → Path → Option Observation
  | o, [] => some o
  | .record xs, .field i :: rest => match xs[i]? with
    | some x => projectObs x rest
    | none => none
  | _, _ => none

def projectVal : Value → Path → Option Value
  | w, [] => some w
  | .record xs, .field i :: rest => match xs[i]? with
    | some x => projectVal x rest
    | none => none
  | _, _ => none

/-- An origin that may name an array a program-lifetime observer reaches:
    shared or unknown, or overlapping a recorded escape (what the Unescaped
    test of a demand rejects). -/
def Escaped (escapes : List Origin) (o : Origin) : Prop :=
  unescaped o = false ∨ cellOverlap [o.base] (escapes.map Origin.base) = true

/-- The configuration invariant of the prefix induction (§6.3, the gap the
    fifth reading named), between a value-semantics state `vs` and an
    in-place state `hs`, for an environment `env` pairing each variable's two
    values, the uses `live` still to come, the abstract environment `aenv`,
    the checker's recorded escapes `escapes` and a naming `γ`:

    * the observations made so far are equal, and so is the fuel left;
    * the permanent observers are the same values on both sides
      (`keptSize`, `kept`), and every array they reach is named only by
      origins the checker considers escaped (`keptEscaped`), so no demand the
      checker passes can write one;
    * every live use (variable and field path) corresponds and is described
      by its abstract value, path by path, with its certificates;
    * every binding, live or dead, keeps its arrays at immutable paths
      (fields, captures, the root) named by its abstract value: a dead binding
      may hold an array since written in place, and its value copy then
      legitimately differs, but the array is still the one its origins name
      (a `close` compares against such a binding without using it);
    * the naming is separating. -/
structure Invariant (vs : ValueSemantics.State) (hs : InPlaceSemantics.State)
    (env : List (Var × Observation × Value)) (live : Live) (aenv : Env Abstract)
    (escapes : List Origin) (γ : Naming) : Prop where
  reads : vs.reads = hs.reads
  external : vs.externalReads = hs.externalReads
  fuel : vs.fuel = hs.fuel
  keptSize : vs.kept.size = hs.kept.size
  kept : ∀ (i : Nat) o w, vs.kept[i]? = some o → hs.kept[i]? = some w → Corresponds hs.heap o w
  keptEscaped : ∀ k ∈ hs.kept.toList, ∀ c, Reaches hs.heap k (.ref c) → ∀ g, c ∈ γ g → Escaped escapes g
  bindings : ∀ x p, (x, p) ∈ live → ∀ o w, env.lookup x = some (o, w) →
    ∃ o' w', projectObs o p = some o' ∧ projectVal w p = some w' ∧ Corresponds hs.heap o' w'
  described : ∀ x p, (x, p) ∈ live → ∀ o w a w', env.lookup x = some (o, w) → aenv.lookup x = some a →
    projectVal w p = some w' → Describes γ hs.heap (a.atPath p) w'
  named : ∀ x o w a, env.lookup x = some (o, w) → aenv.lookup x = some a →
    ∀ q c, immutablePath q = true → ArrayAt hs.heap w q c → named γ (a.cellsAt q) c
  separating : Separating γ

theorem invariant_initial (fuel : Nat) (live : Live) (escapes : List Origin) (γ : Naming)
    (hγ : Separating γ) : Invariant { fuel } { fuel } [] live [] escapes γ :=
  { reads := rfl, external := rfl, fuel := rfl, keptSize := rfl
    kept := by intro i o w h; simp at h
    keptEscaped := by intro k hk; simp at hk
    bindings := by intro x p _ o w h; simp at h
    described := by intro x p _ o w a w' h; simp at h
    named := by intro x o w a h; simp at h
    separating := hγ }

/-- What the invariant buys at the end: the two traces' observation streams
    so far are the same. -/
theorem invariant_observations (h : Invariant vs hs env live aenv escapes γ) :
    vs.reads.toList = hs.reads.toList ∧ vs.externalReads.toList = hs.externalReads.toList :=
  ⟨by rw [h.reads], by rw [h.external]⟩

def valueEnv (env : List (Var × Observation × Value)) : Env Observation := env.map fun (x, o, _) => (x, o)
def heapEnv (env : List (Var × Observation × Value)) : Env Value := env.map fun (x, _, w) => (x, w)

/-- Every function value `a` describes as not once (no roots) is one the
    checker itself would create as not once: re-creating the closure from its
    abstract captures, in an empty context, gives no roots either. A closure
    whose call writes a capture (or calls a once value) is once, and it is
    the once roots that make a call consume it; a description that drops them
    describes a closure the checker would never have built so. -/
def HonestClosures (decls : List Decl) (a : Abstract) : Prop :=
  ∀ q roots alts, a.atPath q = .function roots alts → roots = [] →
    ∀ id caps, (id, caps) ∈ alts → ∃ r st,
      (inferExpr ({} : Config).inferenceFuel { declarations := decls, config := {} }
        (caps.zipIdx.map fun (c, i) => (i, c)) (.closure id ((List.range caps.length).map .var)) [] []).run {} =
        .ok (r, st) ∧ r.roots = []

/-- A value of the value semantics has a type: the ordinary typing the
    type checker gives the expression that produced it. -/
def obsTyped (ds : List Decl) (o : Observation) (t : Ty) : Bool :=
  match o, t with
  | .int _, .int => true
  | .record os, .record ts =>
    os.length == ts.length && (os.attach.zip ts).all fun (o, t) => obsTyped ds o.val t
  | .list os, .list t | .list os, .builder t => os.attach.all fun o => obsTyped ds o.val t
  | .closure id caps, .fn ps r =>
    match ds[id]? with
    | some d => d.parameters == ps && d.result == r && caps.length == d.captures.length &&
        (caps.attach.zip d.captures).all fun (o, t) => obsTyped ds o.val t
    | none => false
  | _, _ => false
termination_by sizeOf o
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem o.property
  all_goals omega

/-- The declaration the type checker checks a main expression as. -/
def mainDecl (e : Expr) : Decl := { name := "main", parameters := [], result := .int, body := e }

/-- `e` is ordinarily typed in a typing of the environment that its values
    have. The checker's abstract domain assumes it: a branch whose arms have
    different shapes joins to an unknown list with no element cells. -/
def WellTyped (ds : List Decl) (env : List (Var × Observation × Value)) (e : Expr) : Prop :=
  ∃ tenv t, exprType ds (mainDecl e) tenv e = .ok t ∧
    ∀ x o w u, env.lookup x = some (o, w) → tenv.lookup x = some u → obsTyped ds o u = true

theorem typesOf_of_typecheck (p : Program) (h : typecheck p = .ok t) : typesOf p = .ok t := by
  unfold typecheck at h
  cases ht : typesOf p with
  | error e => simp [ht, bind, Except.bind] at h
  | ok t' =>
    simp only [ht, bind, Except.bind] at h
    cases hn : noShadowing p with
    | error e => simp [hn] at h
    | ok u => simp [hn, pure, Except.pure] at h; rw [h]

theorem typecheck_main (p : Program) (h : typecheck p = .ok t) :
    exprType p.declarations (mainDecl p.main) [] p.main = .ok t := by
  have h := typesOf_of_typecheck p h
  unfold typesOf at h
  simp only [bind, Except.bind] at h
  split at h
  · contradiction
  · exact h

/-- The corrected checker refuses shadowing (`check` runs `typecheck`). -/
theorem default_refuses_shadowing : ({} : Config).has .shadowing = false := rfl

/-- The context of the main expression of a program the corrected checker
    accepted: the equation fixes every other field of `Context` to its default
    (`owned = []`, `escaped = []`, `recursiveSummary = {}`,
    `recursiveCaptures = []`, `recursiveParameters = []`, `inScope = false`,
    `frames = []`), so nothing is owned, escaped, recursive or framed; the
    configuration is corrected; every cached summary is one the accepted check
    published. -/
def MainContext (p : Program) (a : Accepted) (ctx : Context) (st : St) : Prop :=
  ctx = { declarations := p.declarations, config := ctx.config } ∧ Corrected ctx.config ∧
  ∀ e ∈ st.cache.toList, e ∈ a.cache.toList

/-- **The step case, in the main context only.** In a program the corrected
    checker accepted (`check p = .ok a`), evaluating an expression of the main
    body that the checker accepts in the main context, from checker state
    `st` (whose recorded escapes are `st.facts.escapes`) to `st'`, with the
    abstract environment `aenv` and the continuation's uses `after`, from
    configurations related on the uses of the expression and of its
    continuation, yields configurations related on the continuation's uses
    under the escapes recorded after it, corresponding results described by
    the checker's result `r`, or both evaluations fail. Expressions inside
    function bodies, traversal steps and focus bodies (other contexts) are not
    covered by this statement; there `summary_sound` is the claim. It is the
    simultaneous preservation the thesis says it has not written (§6.3).
    Both interpreters spend fuel identically, so calls that never return
    exhaust the same fuel in both. Unproved. -/
theorem invariant_preserved (p : Program) (a : Accepted) (ok : check p = .ok a)
    (ctx : Context) (aenv : Env Abstract) (e : Expr)
    (after : Live) (site : List Nat) (st st' : St) (r : Abstract) (main : MainContext p a ctx st)
    (accepts : (inferExpr ctx.config.inferenceFuel ctx aenv e after site).run st = .ok (r, st'))
    (fuel : Nat) (env : List (Var × Observation × Value)) (γ : Naming)
    (vs : ValueSemantics.State) (hs : InPlaceSemantics.State)
    (h : Invariant vs hs env (union (uses e) after) aenv st.facts.escapes γ)
    (honest : ∀ x a, aenv.lookup x = some a → HonestClosures p.declarations a)
    (typed : WellTyped p.declarations env e)
    (covered : ∀ x q, (x, q) ∈ union (uses e) after → ∀ o w, env.lookup x = some (o, w) →
      (aenv.lookup x).isSome = true) :
    (∀ v vs', (ValueSemantics.eval fuel p.declarations none (valueEnv env) e).run vs = .ok (v, vs') →
      ∃ w hs' γ', (InPlaceSemantics.eval fuel p.declarations none (heapEnv env) e).run hs = .ok (w, hs') ∧
        Invariant vs' hs' env after aenv st'.facts.escapes γ' ∧ Corresponds hs'.heap v w ∧
        Describes γ' hs'.heap r w ∧ HonestClosures p.declarations r) ∧
    (∀ msg, (ValueSemantics.eval fuel p.declarations none (valueEnv env) e).run vs = .error msg →
      ∃ msg', (InPlaceSemantics.eval fuel p.declarations none (heapEnv env) e).run hs = .error msg') := by
  sorry

theorem check_accepts_main (p : Program) (a : Accepted) (ok : check p = .ok a) :
    ∃ r st', (inferExpr ({} : Config).inferenceFuel { declarations := p.declarations, config := {} }
      [] p.main [] []).run {} = .ok (r, st') ∧ st'.cache = a.cache := by
  unfold check at ok
  simp only [default_refuses_shadowing, Bool.false_eq_true, if_false] at ok
  cases ht : typecheck p with
  | error msg => simp [ht, bind, Except.bind] at ok
  | ok _ =>
    simp only [ht, bind, Except.bind] at ok
    split at ok
    · contradiction
    · rename_i res hrun
      obtain ⟨r, st'⟩ := res
      simp only [pure, Except.pure, Except.ok.injEq] at ok
      exact ⟨r, st', hrun, by rw [← ok]⟩

theorem check_typed (p : Program) (a : Accepted) (ok : check p = .ok a) :
    WellTyped p.declarations [] p.main := by
  unfold check at ok
  simp only [default_refuses_shadowing, Bool.false_eq_true, if_false] at ok
  cases ht : typecheck p with
  | error msg => simp [ht, bind, Except.bind] at ok
  | ok t => exact ⟨[], t, typecheck_main p ht, by intro x o w u h; simp at h⟩

/-- **Main theorem** (Theorem 6.1 for this core). For every program the
    corrected checker accepts and every fuel bound — every execution prefix,
    since both interpreters spend fuel identically — a successful value run is
    matched by a successful in-place run with the same trace: final value,
    every read, and every external observer read. **Conditional**: it is
    `invariant_preserved` at the main expression plus bookkeeping, and holds
    only as far as that unproved lemma does. -/
theorem accepted_traces_agree (p : Program) (a : Accepted) (ok : check p = .ok a)
    (fuel : Nat) (t : Trace) (ht : ValueSemantics.run p fuel = .ok t) :
    ∃ t', InPlaceSemantics.run p fuel = .ok t' ∧ t.reads = t'.reads ∧
      t.externalReads = t'.externalReads ∧ t.finalValue = t'.finalValue := by
  obtain ⟨r, st', accepts, cache⟩ := check_accepts_main p a ok
  have main : MainContext p a { declarations := p.declarations, config := {} } {} :=
    ⟨rfl, corrected_default, by simp⟩
  have inv : Invariant { fuel } { fuel } [] (union (uses p.main) []) [] ({} : St).facts.escapes
      (fun _ => []) :=
    invariant_initial fuel _ _ (fun _ => []) (by intro _ _ _ _ h; simp at h)
  have step := (invariant_preserved p a ok _ [] p.main [] [] {} st' r main accepts fuel
    [] (fun _ => []) { fuel } { fuel } inv (by intro x a h; simp at h) (check_typed p a ok)
    (by intro x q _ o w h; simp at h)).1
  unfold ValueSemantics.run at ht
  cases hv : (ValueSemantics.eval fuel p.declarations none [] p.main).run { fuel } with
  | error msg => simp [hv] at ht; cases ht
  | ok res =>
    obtain ⟨v, vs'⟩ := res
    rw [hv] at ht
    obtain ⟨w, hs', γ', hrun, inv', corr, _⟩ := step v vs' hv
    simp only [bind, Except.bind] at ht
    cases hob : ValueSemantics.observable v with
    | error msg => rw [hob] at ht; cases ht
    | ok u =>
      rw [hob] at ht
      simp only [pure, Except.pure, Except.ok.injEq] at ht
      subst ht
      have shallow : v.depth ≤ observationDepth := by
        unfold ValueSemantics.observable at hob
        split at hob
        · cases hob
        · omega
      refine ⟨{ reads := hs'.reads.toList, finalValue := v, externalReads := hs'.externalReads.toList },
        ?_, by simp [inv'.reads], by simp [inv'.external], rfl⟩
      unfold InPlaceSemantics.run
      simp only [heapEnv, List.map_nil] at hrun
      simp [bind, Except.bind, hrun, corr observationDepth shallow, pure, Except.pure]

/-! ## The review's counterexample to the earlier invariant

Before this restatement `Invariant` related only reads, external reads, fuel
and live bindings. It said nothing of `kept`, so a pre-state whose in-place
side already registered an observer that the value side had not satisfied
every hypothesis of the step lemma, and the very next `observeKept` produced
different external reads. The configuration: `main = 0`, nothing bound, value
state `{fuel := 10}`, in-place state `{fuel := 10, heap := #[[]], kept :=
#[.ref 0]}`. The `#guard`s below run the two interpreters (they fail the build
if the claim stops holding); the theorem shows the restated invariant
excludes the configuration. -/

namespace Counterexample

def program : Program := { main := .atom (.int 0) }
def valueState : ValueSemantics.State := { fuel := 10 }
def heapState : InPlaceSemantics.State := { fuel := 10, heap := #[[]], kept := #[.ref 0] }

-- The old hypotheses: the program and the expression are accepted, reads,
-- external reads and fuel are equal (nothing is bound, so nothing else).
#guard (check program).isOk
#guard ((inferExpr 200 { declarations := [], config := {} } [] program.main [] []).run {}).isOk
#guard valueState.reads.toList == heapState.reads.toList &&
  valueState.externalReads.toList == heapState.externalReads.toList && valueState.fuel == heapState.fuel

/-- The old conclusion fails: both runs succeed, with different external reads. -/
def externalAfter : Option (List (List Observation) × List (List Observation)) :=
  match (ValueSemantics.eval 10 [] none [] program.main).run valueState,
        (InPlaceSemantics.eval 10 [] none [] program.main).run heapState with
  | .ok (_, a), .ok (_, b) => some (a.externalReads.toList, b.externalReads.toList)
  | _, _ => none

#guard match externalAfter with
  | some (a, b) => a.isEmpty && b == [[.list []]]
  | none => false

/-- The restated invariant excludes it: the observers differ in number. -/
theorem old_invariant_counterexample (env : List (Var × Observation × Value)) (live : Live)
    (aenv : Env Abstract) (escapes : List Origin) (γ : Naming) :
    ¬ Invariant valueState heapState env live aenv escapes γ := by
  intro h
  have := h.keptSize
  simp [valueState, heapState] at this

end Counterexample

end Ownership.Soundness
