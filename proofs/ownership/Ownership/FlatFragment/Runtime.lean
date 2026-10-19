import Ownership.FlatFragment.Checker

/-! The first flat fragment: the real observer epilogues, the state frames of the relation, the evaluation equations, allocation, counted writes, integer correspondence, and typing preservation. -/

/-! support for the common expression epilogue.
Complete observer representations justify both real
observer operations. The relation permits nested observers and shared cells.
No theorem uses a pinned soundness obligation. -/

namespace Ownership.FlatFragment.Observe

open InPlaceSemantics HeapProof

private theorem max_fold_bound (values : List Nat) (initial bound : Nat)
    (start : initial ≤ bound) (elements : ∀ value ∈ values, value ≤ bound) :
    values.foldl max initial ≤ bound := by
  induction values generalizing initial with
  | nil => exact start
  | cons value values ih =>
    apply ih (max initial value)
    · exact Nat.max_le.mpr ⟨start, elements value (by simp)⟩
    · intro item member
      exact elements item (by simp [member])

private theorem child_depth_fold_bound (children : List Observation) (bound : Nat)
    (depths : ∀ child ∈ children, child.depth ≤ bound) :
    (children.attach.map fun child => child.val.depth).foldl max 0 ≤ bound := by
  apply max_fold_bound _ _ _ (Nat.zero_le _)
  intro value member
  obtain ⟨child, _, equality⟩ := List.mem_map.mp member
  subst value
  exact depths child.val child.property

mutual
theorem represents_depth_bound (represented : Represents heap depth value observation footprint) :
    observation.depth ≤ depth := by
  cases represented with
  | int => simp [Observation.depth]
  | record children =>
    have bound := child_depth_fold_bound _ _ (representsMany_depth_bound children)
    simpa [Observation.depth, Nat.add_comm] using Nat.add_le_add_left bound 1
  | closure children =>
    have bound := child_depth_fold_bound _ _ (representsMany_depth_bound children)
    simpa [Observation.depth, Nat.add_comm] using Nat.add_le_add_left bound 1
  | ref _ children =>
    have bound := child_depth_fold_bound _ _ (representsMany_depth_bound children)
    simpa [Observation.depth, Nat.add_comm] using Nat.add_le_add_left bound 1

theorem representsMany_depth_bound
    (represented : RepresentsMany heap depth values observations footprint) :
    ∀ observation ∈ observations, observation.depth ≤ depth := by
  cases represented with
  | nil => simp
  | cons first rest =>
    intro observation member
    rcases List.mem_cons.mp member with same | later
    · subst observation
      exact represents_depth_bound first
    · exact representsMany_depth_bound rest observation later
end

theorem representsMany_length
    (represented : RepresentsMany heap depth values observations footprint) :
    values.length = observations.length := by
  induction values generalizing observations footprint with
  | nil => cases represented; rfl
  | cons value values ih =>
    cases represented with
    | cons first rest => simpa using congrArg Nat.succ (ih rest)

theorem representsMany_index {heap : Heap} {w : Value} {o : Observation} {i : Nat} (values : List Value)
    (represented : RepresentsMany heap depth values observations footprint)
    (valueAt : values[i]? = some w) (observationAt : observations[i]? = some o) :
    ∃ cells, Represents heap depth w o cells := by
  induction values generalizing observations footprint i with
  | nil => simp at valueAt
  | cons head tail ih =>
    cases represented with
    | cons first rest =>
      cases i with
      | zero =>
        simp only [List.getElem?_cons_zero, Option.some.injEq] at valueAt observationAt
        subst valueAt
        subst observationAt
        exact ⟨_, first⟩
      | succ i =>
        exact ih rest (by simpa using valueAt) (by simpa using observationAt)

theorem represented_observers_observable
    (represented : RepresentsMany heap observationDepth values observations footprint) :
    observations.forM (m := Except String) ValueSemantics.observable = .ok () := by
  cases represented with
  | nil => rfl
  | cons first rest =>
    have firstSafe := Nat.not_lt.mpr (represents_depth_bound first)
    have restSafe := represented_observers_observable rest
    simp [List.forM, ValueSemantics.observable, firstSafe, restSafe, bind, Except.bind, pure, Except.pure]

def valueObserved (s : ValueSemantics.State) : ValueSemantics.State :=
  if s.kept.isEmpty then s
  else {s with externalReads := s.externalReads.push s.kept.toList}

def heapObserved (s : InPlaceSemantics.State) (observations : List Observation) :
    InPlaceSemantics.State :=
  if s.kept.isEmpty then s
  else {s with externalReads := s.externalReads.push observations}

/-- The actual value epilogue succeeds because the finite witness bounds
every permanent observation at the ordinary observation depth. -/
theorem value_observeKept_run (s : ValueSemantics.State)
    (represented : RepresentsMany heap observationDepth values s.kept.toList footprint) :
    ValueSemantics.observeKept.run s = .ok ((), valueObserved s) := by
  have observed := represented_observers_observable represented
  by_cases empty : s.kept = #[] <;>
    simp [ValueSemantics.observeKept, valueObserved, StateT.run, StateT.bind, StateT.get,
      StateT.set, StateT.pure, StateT.lift, get, getThe, MonadStateOf.get, MonadStateOf.set,
      bind, pure, liftM, monadLift, MonadLift.monadLift, empty, observed, Except.bind, Except.pure]

/-- The actual heap epilogue takes exactly the snapshots in the complete
observer witness. The theorem does not assume an empty observer list. -/
theorem heap_observeKept_run (s : InPlaceSemantics.State)
    (represented : RepresentsMany s.heap observationDepth s.kept.toList observations footprint) :
    InPlaceSemantics.observeKept.run s = .ok ((), heapObserved s observations) := by
  have observed := snapshots_of_represents represented
  by_cases empty : s.kept = #[] <;>
    simp [InPlaceSemantics.observeKept, heapObserved, StateT.run, StateT.bind, StateT.get,
      StateT.set, StateT.pure, StateT.lift, get, getThe, MonadStateOf.get, MonadStateOf.set,
      bind, pure, liftM, monadLift, MonadLift.monadLift, empty, observed, Except.bind, Except.pure]

end Ownership.FlatFragment.Observe

/-! state frames for flat expression preservation.

Runtime depth, runtime state fuel, and inference fuel remain independent.
Complete permanent observer witnesses justify the real expression epilogues.
The relation permits nonempty heaps, observers, and stale dead aliases.
No theorem uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.StateFrame

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Observe

def valueTicked (state : ValueSemantics.State) : ValueSemantics.State :=
  {state with fuel := state.fuel - 1}

def heapTicked (state : InPlaceSemantics.State) : InPlaceSemantics.State :=
  {state with fuel := state.fuel - 1}

def valueAtomPost (state : ValueSemantics.State) : ValueSemantics.State :=
  valueObserved (valueTicked state)

def heapAtomPost (state : InPlaceSemantics.State) (observations : List Observation) :
    InPlaceSemantics.State :=
  heapObserved (heapTicked state) observations

/-- State changes that preserve the heap and observer registrations retain
the relation when the new reads, external streams, and fuel agree. -/
theorem flatInvariant_state_frame
    {vs' : ValueSemantics.State} {hs' : InPlaceSemantics.State}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (heapSame : hs'.heap = hs.heap) (linksSame : hs'.links = hs.links)
    (valueKept : vs'.kept = vs.kept) (heapKept : hs'.kept = hs.kept)
    (reads : vs'.reads = hs'.reads)
    (external : vs'.externalReads = hs'.externalReads)
    (fuel : vs'.fuel = hs'.fuel) :
    FlatInvariant declarations vs' hs' env live aenv tenv escapes gamma := by
  exact {
    toInvariant := {
      reads := reads
      external := external
      fuel := fuel
      keptSize := by simpa only [valueKept, heapKept] using inv.keptSize
      kept := by simpa only [valueKept, heapKept, heapSame] using inv.kept
      keptEscaped := by simpa only [heapKept, heapSame] using inv.keptEscaped
      bindings := by simpa only [heapSame] using inv.bindings
      described := by simpa only [heapSame] using inv.described
      named := by simpa only [heapSame] using inv.named
      separating := inv.separating
      linksValid := Soundness.linksValid_of_empty _ (linksSame.trans inv.links)
      linkNamed := Soundness.linkNamed_of_empty _ _ _ _ (linksSame.trans inv.links)
    }
    heapInts := by simpa only [heapSame] using inv.heapInts
    links := linksSame.trans inv.links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := by simpa only [heapSame] using inv.bindingsTyped
    namingBound := by simpa only [heapSame] using inv.namingBound
    observers := by simpa only [heapSame, valueKept, heapKept] using inv.observers
  }

/-- The computed atom post-states change only fuel and external observer
streams. Their common observer registration count selects the same branch. -/
theorem tick_observer_post_invariant
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    FlatInvariant declarations (valueAtomPost vs) (heapAtomPost hs vs.kept.toList)
      env live aenv tenv escapes gamma := by
  have emptySame : vs.kept.isEmpty = hs.kept.isEmpty := by
    simp only [Array.isEmpty, inv.keptSize]
  cases empty : vs.kept.isEmpty with
  | false =>
    have heapEmpty : hs.kept.isEmpty = false := emptySame.symm.trans empty
    apply flatInvariant_state_frame inv <;>
      simp [valueAtomPost, heapAtomPost, valueObserved, heapObserved,
        valueTicked, heapTicked, empty, heapEmpty, inv.reads, inv.external, inv.fuel]
  | true =>
    have heapEmpty : hs.kept.isEmpty = true := emptySame.symm.trans empty
    apply flatInvariant_state_frame inv <;>
      simp [valueAtomPost, heapAtomPost, valueObserved, heapObserved,
        valueTicked, heapTicked, empty, heapEmpty, inv.reads, inv.external, inv.fuel]

theorem flatInvariant_restrict_live
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (included : ∀ use ∈ nextLive, use ∈ live) :
    FlatInvariant declarations vs hs env nextLive aenv tenv escapes gamma := by
  exact {
    toInvariant := {
      reads := inv.reads
      external := inv.external
      fuel := inv.fuel
      keptSize := inv.keptSize
      kept := inv.kept
      keptEscaped := inv.keptEscaped
      bindings := fun name path member => inv.bindings name path (included _ member)
      described := fun name path member => inv.described name path (included _ member)
      named := inv.named
      separating := inv.separating
      linksValid := Soundness.linksValid_of_empty _ (inv.links)
      linkNamed := Soundness.linkNamed_of_empty _ _ _ _ (inv.links)
    }
    heapInts := inv.heapInts
    links := inv.links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := inv.bindingsTyped
    namingBound := inv.namingBound
    observers := inv.observers
  }

end Ownership.FlatFragment.StateFrame

/-! actual atom runtime equations, for the next generic fragment case.
The caller derives atom runs from prefix bindings. No final execution or
agreement premise enters these equations.
-/

namespace Ownership.FlatFragment.AtomRuntime

open InPlaceSemantics Ownership.FlatFragment.StateFrame

/-- This equation expands only the actual atom expression case.
The observer operation stays intact for the complete-witness theorem. -/
theorem value_atom_eval_equation {depth : Nat} {declarations : List Decl} {a : Atom} (state : ValueSemantics.State)
    (runtimeEnv : Env Observation)
    (atomRun : ValueSemantics.atom runtimeEnv a = .ok value) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.atom a)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (_, post) ← ValueSemantics.observeKept.run (valueTicked state)
        pure (value, post)) := by
  by_cases noDepth : depth = 0
  · simp [ValueSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [ValueSemantics.eval, ValueSemantics.tick, atomRun,
        noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [ValueSemantics.eval, ValueSemantics.tick, atomRun,
        valueTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem heap_atom_eval_equation {depth : Nat} {declarations : List Decl} {a : Atom} (state : InPlaceSemantics.State)
    (runtimeEnv : Env Value)
    (atomRun : InPlaceSemantics.atom runtimeEnv a = .ok value) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.atom a)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (_, post) ← InPlaceSemantics.observeKept.run (heapTicked state)
        pure (value, post)) := by
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, atomRun,
        noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, atomRun,
        heapTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

end Ownership.FlatFragment.AtomRuntime

/-! actual primitive expression runtime equations.
The caller derives operand runs from prefix bindings. No final execution or
agreement premise enters these equations.
-/

namespace Ownership.FlatFragment.PrimitiveRuntime

open InPlaceSemantics Ownership.FlatFragment.StateFrame

/-- This equation expands only the actual atom expression case.
The observer operation stays intact for the complete-witness theorem. -/
theorem value_primitive_eval_equation {depth : Nat} {declarations : List Decl} {op : Prim} {args : List Atom} (state : ValueSemantics.State)
    (runtimeEnv : Env Observation)
    (argsRun : args.mapM (m := Except String) (ValueSemantics.atom runtimeEnv) = .ok values) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.prim op args)).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (value, middle) ← (ValueSemantics.prim op values).run (valueTicked state)
        let (_, post) ← ValueSemantics.observeKept.run middle
        pure (value, post)) := by
  by_cases noDepth : depth = 0
  · simp [ValueSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [ValueSemantics.eval, ValueSemantics.tick, argsRun,
        noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [ValueSemantics.eval, ValueSemantics.tick, argsRun,
        valueTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem heap_primitive_eval_equation {depth : Nat} {declarations : List Decl} {op : Prim} {args : List Atom} (state : InPlaceSemantics.State)
    (runtimeEnv : Env Value)
    (argsRun : args.mapM (m := Except String) (InPlaceSemantics.atom runtimeEnv) = .ok values) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.prim op args)).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (value, middle) ← (InPlaceSemantics.prim op values).run (heapTicked state)
        let (_, post) ← InPlaceSemantics.observeKept.run middle
        pure (value, post)) := by
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, argsRun,
        noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, argsRun,
        heapTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

end Ownership.FlatFragment.PrimitiveRuntime

/-! runtime contracts for generic flat fragment preservation.
The contracts permit nonempty heaps and permanent
observers. The checked demand support supplies the local write-frame premise;
the complete fragment induction must derive empty links and allocated inputs. -/

namespace Ownership.FlatFragment.Runtime

open InPlaceSemantics HeapProof BuilderProof

def heapInts (xs : List Int) : List Value := xs.map Value.int
def valueInts (xs : List Int) : List Observation := xs.map Observation.int

theorem integers_represented (xs : List Int) (depth : Nat) :
    RepresentsMany heap (depth + 1) (heapInts xs) (valueInts xs) [] := by
  induction xs with
  | nil => exact .nil
  | cons x xs ih =>
    simpa [heapInts, valueInts] using RepresentsMany.cons (.int (i := x)) ih

/-- A real flat literal allocates its result and frames complete independent
observers. Observers can share with each other and can have nested values. -/
theorem literal_allocation_contract (s : State) (xs : List Int)
    (outside : RepresentsMany s.heap observationDepth s.kept.toList observers outsideCells) :
    ∃ post, (prim (.literal .int) (heapInts xs)).run s = .ok (.ref s.heap.size, post) ∧
      Represents post.heap observationDepth (.ref s.heap.size) (.list (valueInts xs)) [s.heap.size] ∧
      ExclusiveValue [s.heap.size] outsideCells ∧
      RepresentsMany post.heap observationDepth post.kept.toList observers outsideCells ∧
      post.kept.toList.mapM (snapshot post.heap observationDepth) = .ok observers ∧
      post.fuel = s.fuel ∧ post.reads = s.reads ∧ post.externalReads = s.externalReads := by
  let post := {s with heap := s.heap.push (heapInts xs)}
  have kept := representsMany_after_alloc (xs := heapInts xs) outside
  refine ⟨post, rfl, ?_, ?_, kept, snapshots_of_represents kept, rfl, rfl, rfl⟩
  · exact .ref (by simp [post]) (integers_represented xs (observationDepth - 2))
  · refine ⟨by simp, ?_⟩
    intro first firstMember second secondMember equal
    have fresh : first = s.heap.size := by simpa using firstMember
    have bound := representsMany_bound outside second secondMember
    omega

theorem value_literal_run (s : ValueSemantics.State) (xs : List Int) :
    (ValueSemantics.prim (.literal .int) (valueInts xs)).run s =
      .ok (.list (valueInts xs), s) := rfl

/-- Exact real counted write for the link-free fragment. The counter follows
the runtime's Boolean equality test, without a new equality assumption. -/
theorem writeCounted_empty_run (s : State)
    (lookup : s.heap[root]? = some previous) (links : s.links = []) :
    (writeCounted root stored).run s = .ok (.ref root,
      {s with heap := s.heap.set! root stored, writes := if previous == stored then s.writes else s.writes + 1}) := by
  have valid : root < s.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  have notDangling : ¬ root ≥ s.heap.size := by omega
  dsimp [writeCounted, array, countWrite, writeLinked, write, StateT.run,
    StateT.bind, StateT.map, StateT.get, StateT.set, StateT.modifyGet]
  simp only [pure_bind]
  rw [lookup]
  dsimp [Option.toExcept]
  simp only [pure_bind]
  by_cases equal : (previous == stored) = true
  · simp only [equal, Bool.not_true, Bool.false_eq_true, if_false, if_true]
    dsimp [get, getThe, MonadStateOf.get, modifyGet, MonadStateOf.modifyGet, bind, pure, StateT.bind, StateT.get, StateT.map,
      StateT.modifyGet, StateT.pure, modify]
    simp [notDangling, links, Except.bind, Except.pure, StateT.bind,
      StateT.modifyGet, StateT.pure, bind, pure]
  · have different : (previous == stored) = false := by simpa using equal
    simp only [different, Bool.not_false, Bool.true_eq_false, if_false, if_true]
    dsimp [get, getThe, MonadStateOf.get, modifyGet, MonadStateOf.modifyGet, bind, pure, StateT.bind, StateT.get, StateT.map,
      StateT.modifyGet, StateT.pure, modify]
    simp [notDangling, links, Except.bind, Except.pure, StateT.bind,
      StateT.modifyGet, StateT.pure, bind, pure]

/-- Compose the actual counted write with the observer footprint already
derived by Ownership.FlatFragment.Support.demand_success_observer_footprint. This is a local
write premise, not a global prohibition on aliases in the heap. -/
theorem counted_write_observer_contract (s : State)
    (lookup : s.heap[root]? = some previous) (links : s.links = [])
    (outside : RepresentsMany s.heap depth s.kept.toList observers outsideCells)
    (rootOutside : root ∉ outsideCells) :
    ∃ post, (writeCounted root stored).run s = .ok (.ref root, post) ∧
      RepresentsMany post.heap depth post.kept.toList observers outsideCells ∧
      post.kept.toList.mapM (snapshot post.heap depth) = .ok observers ∧
      post.fuel = s.fuel ∧ post.reads = s.reads ∧ post.externalReads = s.externalReads := by
  let post := {s with heap := s.heap.set! root stored, writes := if previous == stored then s.writes else s.writes + 1}
  have kept := representsMany_after_write (xs := stored) outside rootOutside
  exact ⟨post, writeCounted_empty_run s lookup links, kept,
    snapshots_of_represents kept, rfl, rfl, rfl⟩

end Ownership.FlatFragment.Runtime

/-! push case for the flat fragment.
The theorem executes the real push primitive and
preserves complete independent observers. Ownership.FlatFragment.Support derives its local
observer-frame premise from the actual checker demand and prefix invariant.
The complete expression case must also apply the tick and observer epilogue.
-/

namespace Ownership.FlatFragment.PushRuntime

open InPlaceSemantics HeapProof Ownership.FlatFragment.Runtime

theorem primitive_push_run (s : State) (xs : List Int) (item : Int)
    (lookup : s.heap[root]? = some (heapInts xs)) (links : s.links = []) :
    (prim .push [.ref root, .int item]).run s = .ok (.ref root,
      {s with heap := s.heap.set! root (heapInts xs ++ [.int item]), writes := if heapInts xs == heapInts xs ++ [.int item] then s.writes else s.writes + 1}) := by
  have written := writeCounted_empty_run (root := root)
    (stored := heapInts xs ++ [.int item]) s lookup links
  simpa [prim, array, lookup, StateT.run, StateT.bind, StateT.get,
    Option.toExcept, Except.bind, Except.pure, bind, pure, get, getThe,
    MonadStateOf.get, StateT.pure, StateT.lift, liftM, monadLift, MonadLift.monadLift] using written

theorem value_primitive_push_run (s : ValueSemantics.State) (xs : List Int) (item : Int) :
    (ValueSemantics.prim .push [.list (valueInts xs), .int item]).run s =
      .ok (.list (valueInts (xs ++ [item])), s) := by
  simp [ValueSemantics.prim, valueInts, StateT.run, pure, StateT.pure, Except.pure]

/-- The receiver can have dead aliases. Only the complete permanent observer
footprint must exclude this receiver at the actual checked write site. -/
theorem primitive_push_observer_contract (s : State) (xs : List Int) (item : Int)
    (lookup : s.heap[root]? = some (heapInts xs)) (links : s.links = [])
    (outside : RepresentsMany s.heap observationDepth s.kept.toList observers outsideCells)
    (rootOutside : root ∉ outsideCells) :
    ∃ post,
      (prim .push [.ref root, .int item]).run s = .ok (.ref root, post) ∧
      Represents post.heap observationDepth (.ref root)
        (.list (valueInts (xs ++ [item]))) [root] ∧
      RepresentsMany post.heap observationDepth post.kept.toList observers outsideCells ∧
      post.kept.toList.mapM (snapshot post.heap observationDepth) = .ok observers ∧
      post.fuel = s.fuel ∧ post.reads = s.reads ∧ post.externalReads = s.externalReads := by
  let stored := heapInts xs ++ [.int item]
  let post := {s with heap := s.heap.set! root stored, writes := if heapInts xs == stored then s.writes else s.writes + 1}
  have valid : root < s.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  have storedInts : stored = heapInts (xs ++ [item]) := by
    simp [stored, heapInts]
  have kept := representsMany_after_write (xs := stored) outside rootOutside
  refine ⟨post, primitive_push_run s xs item lookup links, ?_, kept,
    snapshots_of_represents kept, rfl, rfl, rfl⟩
  apply Represents.ref (vs := heapInts (xs ++ [item]))
  · simp [post, storedInts, valid]
  · exact integers_represented (xs ++ [item]) (observationDepth - 2)

end Ownership.FlatFragment.PushRuntime

/-! correspondence for a real allocated integer array at every
sufficient observation depth. Empty lists need one level; nonempty integer
lists need two. The theorem uses the actual executable snapshot.
-/

namespace Ownership.FlatFragment.IntegerCorrespondence

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.Runtime

private theorem fold_ones (integers : List Int) :
    integers.foldl (fun bound _ => max bound 1) 1 = 1 := by
  induction integers with
  | nil => rfl
  | cons integer rest ih => simpa only [List.foldl_cons, Nat.max_self] using ih

theorem observation_list_depth (values : List Observation) :
    (Observation.list values).depth =
      1 + values.foldl (fun bound value => max bound value.depth) 0 := by
  rw [Observation.depth, List.foldl_map]
  congr 1
  exact List.foldl_attach (l := values) (b := 0) (f := fun (bound : Nat) (value : Observation) => max bound value.depth)

theorem integer_list_depth (integers : List Int) :
    (Observation.list (valueInts integers)).depth = if integers = [] then 1 else 2 := by
  rw [observation_list_depth]
  cases integers with
  | nil => rfl
  | cons integer rest =>
    simp [valueInts, List.foldl_map, Observation.depth, fold_ones]

theorem corresponds_integer_ref
    (lookup : heap[root]? = some (heapInts integers)) :
    Corresponds heap (.list (valueInts integers)) (.ref root) := by
  intro depth sufficient
  cases integers with
  | nil =>
    cases depth with
    | zero => simp [integer_list_depth] at sufficient
    | succ depth =>
      exact snapshot_of_represents (Represents.ref lookup RepresentsMany.nil)
  | cons integer rest =>
    have enough : 2 ≤ depth := by simpa [integer_list_depth] using sufficient
    cases depth with
    | zero => omega
    | succ depth =>
      cases depth with
      | zero => omega
      | succ previous =>
        exact snapshot_of_represents
          (Represents.ref lookup (integers_represented (integer :: rest) previous))

theorem observation_of_integer_ref
    (lookup : heap[root]? = some (heapInts integers))
    (paired : Corresponds heap observation (.ref root)) :
    observation = .list (valueInts integers) := by
  let depth := max observation.depth (Observation.list (valueInts integers)).depth
  have ordinary := paired depth (Nat.le_max_left _ _)
  have canonical := corresponds_integer_ref lookup depth (Nat.le_max_right _ _)
  exact Except.ok.inj (ordinary.symm.trans canonical)

end Ownership.FlatFragment.IntegerCorrespondence

/-! allocation and write preservation for every flat binding.
Dead aliases keep their types after a real integer
array mutation. Their old value observations do not have to match the heap.
Live correspondence remains a separate checker-derived preservation duty.
-/

namespace Ownership.FlatFragment.HeapPreservation

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Runtime

theorem integers_of_flat_values (values : List Value)
    (flat : ∀ value ∈ values, ∃ integer, value = .int integer) :
    ∃ integers, values = heapInts integers := by
  induction values with
  | nil => exact ⟨[], rfl⟩
  | cons value values ih =>
    obtain ⟨integer, rfl⟩ := flat value (by simp)
    obtain ⟨integers, rfl⟩ := ih (fun value member => flat value (by simp [member]))
    exact ⟨integer :: integers, rfl⟩

theorem integer_list_observation_typed (declarations : List Decl) (integers : List Int) :
    obsTyped declarations (.list (valueInts integers)) (.list .int) = true := by
  unfold obsTyped
  change (valueInts integers).attach.all (fun item => obsTyped declarations item.val .int) = true
  apply List.all_eq_true.mpr
  intro item _
  obtain ⟨integer, _, equal⟩ := List.mem_map.mp item.property
  rw [← equal]
  simp [obsTyped]

theorem allocated_integer_list_typed {heap : Heap} {root : Nat} {integers : List Int} (declarations : List Decl)
    (allocated : heap[root]? = some (heapInts integers)) :
    ValueTyped declarations heap (.ref root) (.list .int) := by
  refine ⟨observationDepth, .list (valueInts integers), [root], ?_,
    integer_list_observation_typed declarations integers⟩
  exact .ref allocated (integers_represented integers (observationDepth - 2))

/-- The runtime shape of a flat binding: an integer, an allocated array, or a
record of such values. -/
inductive AllocatedFlatValue (heap : Heap) : Value → Ty → Prop where
  | int (integer : Int) : AllocatedFlatValue heap (.int integer) .int
  | list (root : Nat) : root < heap.size → AllocatedFlatValue heap (.ref root) (.list .int)
  | record (ws : List Value) (ts : List Ty) : ws.length = ts.length →
      (∀ (i : Nat) (w : Value) (t : Ty), ws[i]? = some w → ts[i]? = some t →
        AllocatedFlatValue heap w t) →
      AllocatedFlatValue heap (.record ws) (.record ts)

theorem flatHeap_after_write {heap : Heap} {root : Nat} (flat : FlatHeap heap) (allocated : root < heap.size)
    (integers : List Int) : FlatHeap (heap.set! root (heapInts integers)) := by
  intro address values lookup
  by_cases same : address = root
  · subst address
    have payload : heapInts integers = values := by simpa [allocated] using lookup
    rw [← payload]
    intro value member
    obtain ⟨integer, _, equal⟩ := List.mem_map.mp member
    exact ⟨integer, equal.symm⟩
  · rw [lookup_set_other heap root (heapInts integers) same] at lookup
    exact flat address values lookup

theorem flatHeap_after_allocation {heap : Heap} (flat : FlatHeap heap) (integers : List Int) :
    FlatHeap (heap.push (heapInts integers)) := by
  intro address values lookup
  by_cases old : address < heap.size
  · have different : address ≠ heap.size := Nat.ne_of_lt old
    have previous : heap[address]? = some values := by
      simpa [Array.getElem?_push, old, different] using lookup
    exact flat address values previous
  · by_cases last : address = heap.size
    · subst address
      have payload : heapInts integers = values := by simpa using lookup
      rw [← payload]
      intro value member
      obtain ⟨integer, _, equal⟩ := List.mem_map.mp member
      exact ⟨integer, equal.symm⟩
    · simp [Array.getElem?_push, old, last] at lookup

end Ownership.FlatFragment.HeapPreservation
