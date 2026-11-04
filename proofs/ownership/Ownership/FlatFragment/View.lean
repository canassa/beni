import Ownership.FlatFragment.Dictionary

/-! The view in the flat fragment (#169).

`view front xs` is all but the first element of `xs` (`front`) or all but
the last. The value interpreter builds that list. The heap interpreter
allocates an array of its own that holds the same elements
(`viewOf front ys`), and links it to its source when the source is nonempty;
an empty source gives a fresh `[]` with no link. The checker records a read
of the source and describes the view by the source's description with the
fresh site among its roots.

The post-naming adds the new address to every origin that names the source
(`view_naming`). So it keeps every old array's origins, and it names the view
by exactly its source's origins, which is what `linkClosed_viewed` asks; the
view's root is still named by a root of its abstract. The view's elements are
a sublist of the source's, so the source's exclusivity and spine certificates
carry over to the view (`view_footprint_nodup`, `view_footprint_once`). -/

namespace Ownership.FlatFragment.View

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.PrimitiveInference Ownership.FlatFragment.PrimitiveRuntime
open Ownership.FlatFragment.Naming Ownership.FlatFragment.Support Ownership.FlatFragment.IntegerCorrespondence Ownership.FlatFragment.Fields
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.Push
open Ownership.FlatFragment.LiveCells Ownership.FlatFragment.Scope Ownership.FlatFragment.NamingFacts
open Ownership.FlatFragment.Static Ownership.FlatFragment.ListPrimitives Ownership.FlatFragment.Let
open Ownership.FlatFragment.Dictionary

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-! ### The elements of a view -/

/-- The value interpreter's view of a list. -/
def viewObs (front : Bool) (os : List Observation) : List Observation :=
  if front then os.drop 1 else os.dropLast

theorem viewOf_sublist (front : Bool) (ys : List Value) : (viewOf front ys).Sublist ys := by
  unfold viewOf
  split
  · exact List.drop_sublist _ _
  · exact List.dropLast_sublist _

theorem viewObs_sublist (front : Bool) (os : List Observation) : (viewObs front os).Sublist os := by
  unfold viewObs
  split
  · exact List.drop_sublist _ _
  · exact List.dropLast_sublist _

theorem viewOf_length (front : Bool) (ys : List Value) : (viewOf front ys).length = ys.length - 1 := by
  unfold viewOf
  split <;> simp

theorem viewObs_length (front : Bool) (os : List Observation) : (viewObs front os).length = os.length - 1 := by
  unfold viewObs
  split <;> simp

/-- The view's elements correspond position by position. -/
theorem view_pointwise {heap : Heap} (front : Bool) {os : List Observation} {ys : List Value}
    (lenO : os.length = ys.length)
    (pointwise : ∀ (i : Nat) o y, os[i]? = some o → ys[i]? = some y → Corresponds heap o y) :
    ∀ (i : Nat) o y, (viewObs front os)[i]? = some o → (viewOf front ys)[i]? = some y →
      Corresponds heap o y := by
  intro i o y os_i ys_i
  unfold viewObs at os_i
  unfold viewOf at ys_i
  cases front with
  | true =>
    simp only [if_true, List.getElem?_drop] at os_i ys_i
    exact pointwise (1 + i) o y os_i ys_i
  | false =>
    simp only [Bool.false_eq_true, if_false, List.dropLast_eq_take, List.getElem?_take] at os_i ys_i
    split at os_i
    · split at ys_i
      · exact pointwise i o y os_i ys_i
      · cases ys_i
    · cases os_i

/-! ### Certificates over a sublist of the source's elements -/

/-- A sublist's representation and the whole list's one make a
representation of the whole list whose footprint holds the sublist's
footprint as a sublist. -/
theorem representsMany_sublist_merge {heap : Heap} :
    ∀ {zs ys : List Value}, zs.Sublist ys → ∀ {n m : Nat} {os os0 : List Observation} {cs cs0 : List Nat},
      RepresentsMany heap n zs os cs → RepresentsMany heap m ys os0 cs0 →
      ∃ os' cs', RepresentsMany heap (max n m) ys os' cs' ∧ cs.Sublist cs' := by
  intro zs ys sub
  induction sub with
  | slnil =>
    intro n m os os0 cs cs0 kept _
    cases kept
    exact ⟨[], [], .nil, List.Sublist.refl _⟩
  | cons y _ ih =>
    intro n m os os0 cs cs0 kept all
    cases all with
    | @cons _ _ oy0 fy0 _ _ cs0' firstAll restAll =>
      obtain ⟨os', cs', merged, sub⟩ := ih kept restAll
      refine ⟨oy0 :: os', fy0 ++ cs', .cons (Ownership.FlatFragment.RepresentsDepth.represents_of_depth firstAll ?_) merged,
        List.Sublist.trans sub (List.sublist_append_right fy0 cs')⟩
      exact Nat.le_trans (represents_depth_bound firstAll) (Nat.le_max_right n m)
  | cons₂ y _ ih =>
    intro n m os os0 cs cs0 kept all
    cases kept with
    | @cons _ _ oy fy _ _ csRest first rest =>
      cases all with
      | @cons _ _ oy0 fy0 _ _ cs0' firstAll restAll =>
        obtain ⟨os', cs', merged, sub⟩ := ih rest restAll
        refine ⟨oy :: os', fy ++ cs', .cons (Ownership.FlatFragment.RepresentsDepth.represents_of_depth first ?_) merged,
          List.Sublist.append (List.Sublist.refl fy) sub⟩
        exact Nat.le_trans (represents_depth_bound first) (Nat.le_max_left n m)

/-- A fresh array of some of the source's elements repeats no array when the
source does not. -/
theorem view_footprint_nodup {heap next : Heap} {root new : Nat} {ys zs : List Value}
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (sub : zs.Sublist ys)
    (lookup : heap[root]? = some ys) (lookupNew : next[new]? = some zs)
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (agreeOld : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (newApart : ∀ y ∈ zs, ¬ Reaches heap y (.ref new))
    (oldNodup : ∀ n o fp, Represents heap n (.ref root) o fp → fp.Nodup) :
    ∀ n o fp, Represents next n (.ref new) o fp → fp.Nodup := by
  intro n o fp rep
  cases rep with
  | @ref _ _ n' _ _ lookup' children =>
    rw [lookupNew] at lookup'
    cases lookup'
    have childrenHeap := representsMany_elements_apart children
      (fun y member => agreeOld y (sub.subset member))
    cases represented with
    | @ref _ _ n1 _ _ lookup0 children0 =>
      rw [lookup] at lookup0
      cases lookup0
      obtain ⟨os', cs', merged, subFp⟩ := representsMany_sublist_merge sub childrenHeap children0
      have oldOk := oldNodup _ _ _ (.ref lookup merged)
      rw [List.nodup_cons] at oldOk ⊢
      refine ⟨fun member => ?_, subFp.nodup oldOk.2⟩
      obtain ⟨z, zMember, reach⟩ :=
        Ownership.FlatFragment.Support.representsMany_footprint_reaches childrenHeap new member
      exact newApart z zMember reach

/-- An array at a container position of the view appears once in its
footprint when it appears once in the source's. -/
theorem view_footprint_once {heap next : Heap} {root new : Nat} {ys zs : List Value}
    {n0 : Nat} {o0 : Observation} {fp0 : List Nat}
    (sub : zs.Sublist ys)
    (lookup : heap[root]? = some ys) (lookupNew : next[new]? = some zs)
    (represented : Represents heap n0 (.ref root) o0 fp0)
    (agreeOld : ∀ y ∈ ys, ∀ c, Reaches heap y (.ref c) → next[c]? = heap[c]?)
    (newApart : ∀ y ∈ zs, ¬ Reaches heap y (.ref new))
    (oldOnce : ∀ n o fp, Represents heap n (.ref root) o fp →
      ∀ q c, containerPath q = true → ArrayAt heap (.ref root) (.element :: q) c → fp.count c = 1) :
    ∀ n o fp, Represents next n (.ref new) o fp →
      ∀ q c, containerPath q = true → ArrayAt next (.ref new) (.element :: q) c → fp.count c = 1 := by
  intro n o fp rep q c container located
  cases rep with
  | @ref _ _ n' _ _ lookup' children =>
    rw [lookupNew] at lookup'
    cases lookup'
    have childrenHeap := representsMany_elements_apart children
      (fun y member => agreeOld y (sub.subset member))
    cases represented with
    | @ref _ _ n1 _ _ lookup0 children0 =>
      rw [lookup] at lookup0
      cases lookup0
      obtain ⟨os', cs', merged, subFp⟩ := representsMany_sublist_merge sub childrenHeap children0
      cases located with
      | @element _ _ z _ _ lookup'' member inner =>
        rw [lookupNew] at lookup''
        cases lookup''
        have zOld : z ∈ ys := sub.subset member
        have innerHeap : AtPath heap z q (.ref c) := atPath_of_agree_rev (agreeOld z zOld) inner
        have oldCount := oldOnce _ _ _ (.ref lookup merged) q c container (.element lookup zOld innerHeap)
        have inKept : c ∈ _ :=
          Ownership.FlatFragment.FiniteReach.representsMany_reach_member childrenHeap member
            (reaches_of_atPath innerHeap)
        have notNew : c ≠ new := by
          intro same
          subst same
          exact newApart z member (reaches_of_atPath innerHeap)
        have le := (List.Sublist.cons root subFp).count_le c
        have pos : 0 < _ := List.count_pos_iff.mpr inKept
        rw [List.count_cons, if_neg (by simpa using Ne.symm notNew)]
        omega

/-! ### The naming -/

/-- The naming after a view: the new address joins every origin that names
the source, and every old array keeps its origins. -/
theorem view_naming {gamma : Naming} {size : Nat} (bound : Ownership.FlatFragment.State.NamingBound gamma size)
    (separating : Separating gamma) (c : Nat) :
    ∃ gamma', (∀ o cell, cell < size → (cell ∈ gamma' o ↔ cell ∈ gamma o)) ∧
      (∀ o, size ∈ gamma' o ↔ c ∈ gamma o) ∧ Ownership.FlatFragment.State.NamingBound gamma' (size + 1) ∧
      Separating gamma' := by
  let gamma' : Naming := fun o => if c ∈ gamma o then gamma o ++ [size] else gamma o
  have member : ∀ o cell, cell ∈ gamma' o ↔ cell ∈ gamma o ∨ (c ∈ gamma o ∧ cell = size) := by
    intro o cell
    by_cases named : c ∈ gamma o
    · simp [gamma', named]
    · simp [gamma', named]
  have notOld : ∀ o, size ∉ gamma o := fun o inside => by
    have := bound o size inside
    omega
  refine ⟨gamma', ?_, ?_, ?_, ?_⟩
  · intro o cell lt
    rw [member]
    constructor
    · rintro (old | ⟨_, rfl⟩)
      · exact old
      · omega
    · exact Or.inl
  · intro o
    rw [member]
    constructor
    · rintro (old | ⟨named, _⟩)
      · exact absurd old (notOld o)
      · exact named
    · intro named
      exact Or.inr ⟨named, rfl⟩
  · intro o cell inside
    rcases (member o cell).mp inside with old | ⟨_, rfl⟩
    · have := bound o cell old
      omega
    · omega
  · intro a b different cell insideA insideB
    rcases (member a cell).mp insideA with oldA | ⟨namedA, sameA⟩
    · rcases (member b cell).mp insideB with oldB | ⟨_, sameB⟩
      · exact separating a b different cell oldA oldB
      · rw [sameB] at oldA
        exact notOld a oldA
    · rcases (member b cell).mp insideB with oldB | ⟨namedB, _⟩
      · rw [sameA] at oldB
        exact notOld b oldB
      · exact separating a b different c namedA namedB

/-! ### The heap typing -/

/-- The heap typing after a view: the new array is a list of the source's
type, and so is a new link's view end. -/
theorem view_kinds {kinds : Nat → Option Ty} {hs hs' : State} {env : List (Var × Observation × Value)}
    {tenv : Env Ty} (state : StateKinded kinds hs env tenv) {root : Nat} {t : Ty} {front : Bool}
    {ys : List Value} (typed : kinds root = some (.list t)) (lookup : hs.heap[root]? = some ys)
    (heap : hs'.heap = hs.heap.push (viewOf front ys))
    (links : hs'.links = hs.links ∨ hs'.links = hs.links ++ [(hs.heap.size, root, front)]) :
    ∃ kinds', StateKinded kinds' hs' env tenv ∧ kinds' hs.heap.size = some (.list t) := by
  let mid : State := {hs with heap := hs.heap.push (viewOf front ys)}
  obtain ⟨kinds', state', mono, newTyped⟩ := state.of_alloc (hs' := mid)
    (.list t _ fun x member => state.list_contents typed lookup x ((viewOf_sublist front ys).subset member))
    rfl rfl
  refine ⟨kinds', ⟨?_, ?_, state'.env⟩, newTyped⟩
  · rw [heap]
    exact state'.heap
  · intro v s f member
    rcases links with same | added
    · rw [same] at member
      exact state'.links v s f member
    · rw [added] at member
      rcases List.mem_append.mp member with old | new
      · exact state'.links v s f old
      · simp only [List.mem_singleton, Prod.mk.injEq] at new
        obtain ⟨sameV, sameS, _⟩ := new
        rw [sameV, sameS]
        exact ⟨t, newTyped, mono root _ typed⟩

/-! ### The runtime -/

/-- The links after a view: a new link when the source is nonempty. -/
def viewLinks (hs : State) (root : Nat) (front : Bool) (ys : List Value) : List (Nat × Nat × Bool) :=
  if ys = [] then hs.links else hs.links ++ [(hs.heap.size, root, front)]

def heapViewed (hs : State) (root : Nat) (front : Bool) (ys : List Value) : State :=
  { hs with fuel := hs.fuel - 1, heap := hs.heap.push (viewOf front ys), links := viewLinks hs root front ys }

theorem value_view_run (s : ValueSemantics.State) (front : Bool) (os : List Observation) :
    (ValueSemantics.prim (.view front) [.list os]).run s = .ok (.list (viewObs front os), s) := rfl

theorem heap_view_prim_run (hs : State) (front : Bool) {root : Nat} (ys : List Value)
    (lookup : hs.heap[root]? = some ys) :
    (prim (.view front) [.ref root]).run (heapTicked hs) = .ok (.ref hs.heap.size, heapViewed hs root front ys) := by
  by_cases empty : ys = []
  · subst empty
    simp [prim, array, alloc, lookup, heapTicked, heapViewed, viewLinks, viewOf, Option.toExcept, StateT.run,
      StateT.bind, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure,
      bind, pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift]
  · have notEmpty : ys.isEmpty = false := by simpa using empty
    simp [prim, array, alloc, lookup, heapTicked, heapViewed, viewLinks, empty, notEmpty, Option.toExcept,
      StateT.run, StateT.bind, StateT.get, StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure,
      bind, pure, get, getThe, set, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift,
      modify, modifyGet, MonadStateOf.modifyGet, StateT.modifyGet]

theorem view_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {receiver : Atom} {front : Bool} {os : List Observation} {ys : List Value} {root : Nat} {depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (valueReceiver : ValueSemantics.atom (valueEnv env) receiver = .ok (.list os))
    (heapReceiver : InPlaceSemantics.atom (heapEnv env) receiver = .ok (.ref root))
    (lookup : hs.heap[root]? = some ys)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.prim (.view front) [receiver])).run vs =
      .ok (.list (viewObs front os), valueObserved (valueTicked vs)) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.prim (.view front) [receiver])).run hs =
      .ok (.ref hs.heap.size, heapObserved (heapViewed hs root front ys) vs.kept.toList) := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapViewed hs root front ys)
    (representsMany_after_alloc (xs := viewOf front ys) represented)
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os] := except_mapM_cons valueReceiver rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root] := except_mapM_cons heapReceiver rfl
  constructor
  · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms]
    simp [hasDepth, hasFuel, value_view_run, valueObservedRun, Except.bind, Except.pure, bind, pure]
  · rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
    simp [hasDepth, heapFuel, heap_view_prim_run hs front ys lookup, heapObservedRun,
      Except.bind, Except.pure, bind, pure]

/-! ### The case -/

theorem view_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {receiver : Atom} {front : Bool} {type : Ty} {self : Decl} {ctx : Context} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel depth : Nat}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.prim (.view front) [receiver]) = .ok type)
    (covered : ∀ use ∈ atomUses receiver, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim (.view front) [receiver]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ next.facts.escapes = before.facts.escapes ∧ FlatAbstract type result ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.view front) [receiver])).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.view front) [receiver])).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual ∧
        KindsAt hs' env tenv type actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.prim (.view front) [receiver])).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.prim (.view front) [receiver])).run hs = .error actualMessage) := by
  obtain ⟨t, receiverTyped, listType⟩ := exprType_view_success (fun _ _ h => flat_atom_type inv h) typed
  subst listType
  obtain ⟨root, ys, os, roots, element, certificate, lookup, receiverNamed, noUnk, elemT, elemTags, elemShape0,
    elemsShaped, elemsDescribed, lenO, elemsTyped, pointwise, pairedList, described, valueReceiver, heapReceiver,
    abstractReceiver⟩ := flat_atom_list_path inv receiverTyped covered
  have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.list roots element certificate] := except_mapM_cons abstractReceiver rfl
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_view_run] at run
  have equal := Except.ok.inj run
  have resultEq : result = .list (union roots [.site site 0]) element certificate := by
    have h := (congrArg Prod.fst equal).symm
    rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
      defaultConfig, default_has] at h
    exact h
  have resultRep : entryAbstract declarations (.list t) result =
      .list (union roots [.site site 0]) (entryAbstract declarations t element) certificate := by
    rw [resultEq]; rfl
  have nextState : next = {before with facts := {before.facts with
      reads := union before.facts.reads (roots.filter external)}} := (congrArg Prod.snd equal).symm
  have nextEscapes : next.facts.escapes = before.facts.escapes := by
    subst nextState; rfl
  have noUnk' : Origin.unknown ∉ union roots [.site site 0] := by
    intro member
    rcases mem_union_cases _ _ _ member with old | new
    · exact noUnk old
    · simp at new
  have valueAtoms : [receiver].mapM (m := Except String) (ValueSemantics.atom (valueEnv env)) =
      .ok [.list os] := except_mapM_cons valueReceiver rfl
  have heapAtoms : [receiver].mapM (m := Except String) (InPlaceSemantics.atom (heapEnv env)) =
      .ok [.ref root] := except_mapM_cons heapReceiver rfl
  refine ⟨.list t elemT, nextEscapes, by rw [resultEq]; exact .list _ _ _ _ noUnk' elemShape0, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_primitive_eval_equation vs (valueEnv env) valueAtoms] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun⟩ :=
          view_runtime_success (front := front) inv valueReceiver heapReceiver lookup noDepth noFuel
        rw [valueRun] at run
        cases run
        have rootLt : root < hs.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
        have heapEq : (heapObserved (heapViewed hs root front ys) vs.kept.toList).heap =
            hs.heap.push (viewOf front ys) := by
          rw [heapObserved_heap]; rfl
        have linksEq : (heapObserved (heapViewed hs root front ys) vs.kept.toList).links =
            viewLinks hs root front ys := by
          rw [heapObserved_links]; rfl
        have sub := viewOf_sublist front ys
        have agree : ∀ y ∈ ys, ∀ c, Reaches hs.heap y (.ref c) →
            (hs.heap.push (viewOf front ys))[c]? = hs.heap[c]? := by
          intro y member c reach
          have bound := allocated_reach_bound (elemsShaped y member) reach
          simp [Array.getElem?_push, Nat.ne_of_lt bound]
        -- The naming names the view by its source's origins.
        obtain ⟨gamma', old, viewNamed, bounded, separating⟩ :=
          view_naming (size := hs.heap.size) (fun o a m => inv.namingBound o a m) inv.separating root
        -- The links: a view of a nonempty source is linked to it.
        have linksCases : (heapObserved (heapViewed hs root front ys) vs.kept.toList).links = hs.links ∧ ys = [] ∨
            (heapObserved (heapViewed hs root front ys) vs.kept.toList).links =
              hs.links ++ [(hs.heap.size, root, front)] ∧ ys ≠ [] := by
          rw [linksEq]
          by_cases empty : ys = []
          · exact Or.inl ⟨by simp [viewLinks, empty], empty⟩
          · exact Or.inr ⟨by simp [viewLinks, empty], empty⟩
        have linksValid' : LinksValid (heapObserved (heapViewed hs root front ys) vs.kept.toList) := by
          rcases linksCases with ⟨same, _⟩ | ⟨added, nonempty⟩
          · exact Ownership.LinkClauses.linksValid_of_same
              (Ownership.LinkClauses.linksValid_push inv.toInvariant.linksValid (viewOf front ys)) heapEq same
          · exact Ownership.LinkClauses.linksValid_of_same
              (Ownership.LinkClauses.linksValid_viewed inv.toInvariant.linksValid root front ys lookup nonempty)
              heapEq added
        have linkClosed' : Ownership.LinkClauses.LinkClosed
            (heapObserved (heapViewed hs root front ys) vs.kept.toList).links gamma' := by
          rcases linksCases with ⟨same, _⟩ | ⟨added, _⟩
          · rw [same]
            exact Ownership.LinkClauses.linkClosed_of_old inv.toInvariant.linksValid inv.linkClosed old
          · rw [added]
            exact Ownership.LinkClauses.linkClosed_viewed inv.toInvariant.linksValid inv.linkClosed root front
              old viewNamed rootLt
        -- The heap typing.
        obtain ⟨kinds, state⟩ := inv.heapKinds
        have rootTyped : kinds root = some (.list t) := by
          obtain ⟨c0, same0, typed0⟩ := kinded_list_inv (kinded_atom inv state receiverTyped covered heapReceiver)
          cases same0
          exact typed0
        obtain ⟨kinds', state', newTyped⟩ := view_kinds state rootTyped lookup heapEq (by
          rcases linksCases with ⟨same, _⟩ | ⟨added, _⟩
          · exact Or.inl same
          · exact Or.inr added)
        obtain ⟨footprint, represented⟩ := inv.observers
        have postInvariant : FlatInvariant declarations (valueObserved (valueTicked vs))
            (heapObserved (heapViewed hs root front ys) vs.kept.toList) env live aenv tenv before.facts.escapes
            gamma' := by
          refine flatInvariant_heap_frame inv (inside := (· = hs.heap.size)) (footprint := footprint)
            (fun _ member => member) (by rw [heapEq]; simp) linksValid' linkClosed' ?_ ?_
            represented ?_ (by rw [heapObserved_kept]; rfl) (by rw [valueObserved_kept]; rfl) old ?_ separating
            (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
            (observed_external (valueTicked vs) (heapViewed hs root front ys) inv.keptSize inv.external)
            (by rw [valueObserved_fuel, heapObserved_fuel]; simp [valueTicked, heapViewed, inv.fuel])
            (fun _ escaped => escaped) ⟨kinds', state'⟩
          · intro c different
            rw [heapEq]
            simp [Array.getElem?_push, show c ≠ hs.heap.size from different]
          · intro x p _ o w w' binding projected q c located same
            have := live_path_below inv x p o w w' binding projected q c located
            omega
          · intro c member same
            have bound := representsMany_bound represented _ member
            omega
          · rw [heapEq]
            simp only [Array.size_push]
            exact bounded
        have lookupNew : (hs.heap.push (viewOf front ys))[hs.heap.size]? = some (viewOf front ys) := by simp
        have shapedNew : AllocatedFlatValue (hs.heap.push (viewOf front ys)) (.ref hs.heap.size)
            (.list (entryType t)) :=
          .list _ _ (entryType t) lookupNew (fun y member =>
            allocated_of_agree (elemsShaped y (sub.subset member)) (agree y (sub.subset member)))
        have rootNamed' : named gamma' (union roots [.site site 0]) hs.heap.size := by
          obtain ⟨origin, originMember, rootIn⟩ := receiverNamed
          exact ⟨origin, mem_union _ _ _ (Or.inl originMember), (viewNamed origin).mpr rootIn⟩
        have newApart : ∀ y ∈ viewOf front ys, ¬ Reaches hs.heap y (.ref hs.heap.size) := by
          intro y member reach
          have := allocated_reach_bound (elemsShaped y (sub.subset member)) reach
          omega
        obtain ⟨cs0, represented0⟩ := represents_of_snapshot _ _ _ (pairedList _ (Nat.le_refl _))
        have oldCert := described.1.2 [] roots (entryAbstract declarations t element) certificate (.ref root) rfl
          (.here _)
        have pairedNew : Corresponds (hs.heap.push (viewOf front ys)) (.list (viewObs front os))
            (.ref hs.heap.size) :=
          corresponds_list_of_elements lookupNew (by rw [viewObs_length, viewOf_length, lenO])
            (view_pointwise front lenO (fun i o y os_i ys_i =>
              corresponds_of_agree (agree y (List.mem_of_getElem? ys_i)) (pointwise i o y os_i ys_i)))
        have observedNew : obsTyped declarations (.list (viewObs front os)) (.list t) = true :=
          obsTyped_list_of_elements (fun o member => elemsTyped o ((viewObs_sublist front os).subset member))
        refine ⟨.ref hs.heap.size, heapObserved (heapViewed hs root front ys) vs.kept.toList, gamma',
          heapRun, by rw [nextEscapes]; exact postInvariant, by rw [heapEq]; simp, by rw [heapEq]; exact pairedNew,
          ?_, observedNew, by rw [heapEq]; exact valueTyped_of_corresponds pairedNew observedNew,
          by rw [heapEq]; exact shapedNew, by rw [resultRep]; exact .list _ _ _ _ _, .list _ _ _, ?_,
          ⟨kinds', state', .list t _ newTyped⟩⟩
        · rw [heapEq, resultRep]
          refine list_described_of_elements rootNamed' noUnk' lookupNew shapedNew ?_ ?_ ?_
          · intro y member
            have yOld := sub.subset member
            exact describes_of_agree (agree y yOld) (describes_naming_same (elemsShaped y yOld) old
              (fun c reach => allocated_reach_bound (elemsShaped y yOld) reach) (elemsDescribed y yOld))
          · intro deep
            exact view_footprint_nodup sub lookup lookupNew represented0 agree newApart
              (fun n o fp rep => (oldCert n o fp rep).1 deep)
          · intro spine
            exact view_footprint_once sub lookup lookupNew represented0 agree newApart
              (fun n o fp rep => (oldCert n o fp rep).2 spine)
        · rw [heapEq, resultRep]
          exact tagsDeep_list lookupNew (fun y member =>
            elementTags_of_agree (elemTags y (sub.subset member)) (agree y (sub.subset member)))
  · intro message failed
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", by
        rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
        simp [noDepth]⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
        exact ⟨"in-place execution exhausted fuel", by
          rw [heap_primitive_eval_equation hs (heapEnv env) heapAtoms]
          simp [noDepth, heapFuel]⟩
      · have success := (view_runtime_success (front := front) inv valueReceiver heapReceiver lookup noDepth
          noFuel).1
        rw [success] at failed
        contradiction

end Ownership.FlatFragment.View
