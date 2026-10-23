import Ownership.FlatFragment.Runtime

/-! The first flat fragment: typed integer atoms, the variable runtime, and the two atom expression cases. -/

/-! typed integer atoms from the actual prefix environments.
The checker lookup, ordinary typing, and both runtime atom functions remain
unchanged. The active root comes from the caller's syntactic uses.
-/

namespace Ownership.FlatFragment.AtomInteger

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Support
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.Env Ownership.FlatFragment.HeapPreservation

theorem observation_integer_of_type
    (typed : obsTyped declarations observation .int = true) :
    ∃ integer : Int, observation = .int integer := by
  cases observation with
  | int integer => exact ⟨integer, rfl⟩
  | record values => simp [obsTyped] at typed
  | list values => simp [obsTyped] at typed
  | closure id captures => simp [obsTyped] at typed

end Ownership.FlatFragment.AtomInteger

/-! variable runtime preservation from an actual prefix binding.
The variable's live path supplies correspondence and description. Complete
observer witnesses justify both real expression epilogues.
-/

namespace Ownership.FlatFragment.VariableRuntime

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Env Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.AtomRuntime

theorem variable_runtime_success {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {depth : Nat} {key : Var} {observation : Observation} {actual : Value}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (binding : env.lookup key = some (observation, actual))
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (valueEnv env) (.atom (.var key))).run vs =
      .ok (observation, valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (heapEnv env) (.atom (.var key))).run hs =
      .ok (actual, heapAtomPost hs vs.kept.toList) ∧
    FlatInvariant declarations (valueAtomPost vs) (heapAtomPost hs vs.kept.toList)
      env live aenv tenv escapes gamma := by
  obtain ⟨valueAtom, heapAtom⟩ := variable_atoms_run binding
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapTicked hs) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  refine ⟨?_, ?_, tick_observer_post_invariant inv⟩
  · rw [value_atom_eval_equation vs (valueEnv env) valueAtom]
    simp [hasDepth, hasFuel, valueObservedRun, valueAtomPost, Except.bind, Except.pure]
  · rw [heap_atom_eval_equation hs (heapEnv env) heapAtom]
    simp [hasDepth, heapFuel, heapObservedRun, heapAtomPost, Except.bind, Except.pure]

theorem variable_post_correspondence {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} {key : Var} {observation : Observation} {actual : Value} {abstract : Abstract}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (use : (key, []) ∈ live)
    (binding : env.lookup key = some (observation, actual))
    (abstractBinding : aenv.lookup key = some abstract) :
    Corresponds (heapAtomPost hs vs.kept.toList).heap observation actual ∧
      Describes gamma (heapAtomPost hs vs.kept.toList).heap abstract actual := by
  have facts := live_variable_result inv use binding abstractBinding
  have heapSame : (heapAtomPost hs vs.kept.toList).heap = hs.heap := by
    unfold heapAtomPost heapObserved heapTicked
    split <;> rfl
  rw [heapSame]
  exact ⟨facts.1, facts.2.1⟩

end Ownership.FlatFragment.VariableRuntime

/-! integer-atom preservation case.

Runtime depth, runtime state fuel, and inference fuel remain independent.
Complete permanent observer witnesses justify the real expression epilogues.
The relation permits nonempty heaps, observers, and stale dead aliases.
No theorem uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.AtomPreservation

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
    links := linksSame.trans inv.links
    abstractKeys := inv.abstractKeys
    typeKeys := inv.typeKeys
    types := inv.types
    abstractShapes := inv.abstractShapes
    bindingsTyped := by simpa only [heapSame] using inv.bindingsTyped
    tags := inv.tags
    chains := inv.chains
    liveTyped := inv.liveTyped
    namingBound := by simpa only [heapSame] using inv.namingBound
    observers := by simpa only [heapSame, valueKept, heapKept] using inv.observers
  }

/-- The computed atom post-states change only fuel and external observer
streams. Their common observer registration count selects the same branch. -/
theorem integer_atom_post_invariant
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

theorem integer_corresponds (integer : Int) :
    Corresponds heap (.int integer) (.int integer) := by
  intro depth enough
  cases depth with
  | zero => simp [Observation.depth] at enough
  | succ depth => rfl

theorem integer_described (integer : Int) :
    Describes gamma heap .scalar (.int integer) := by
  refine ⟨⟨?_, ?_⟩, ClosureAgreement.int .scalar integer⟩
  · intro path address located
    cases located
  · intro path roots element certificate value shape located
    cases located with
    | here => cases shape

/-- This equation expands only the actual integer expression case.
The observer operation stays intact for the complete-witness theorem. -/
theorem value_integer_eval_equation (state : ValueSemantics.State)
    (runtimeEnv : Env Observation) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.atom (.int integer))).run state =
      (if depth = 0 then .error "value execution exhausted depth"
      else if state.fuel = 0 then .error "value execution exhausted fuel"
      else do
        let (_, post) ← ValueSemantics.observeKept.run (valueTicked state)
        pure (.int integer, post)) := by
  by_cases noDepth : depth = 0
  · simp [ValueSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [ValueSemantics.eval, ValueSemantics.tick, ValueSemantics.atom,
        noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [ValueSemantics.eval, ValueSemantics.tick, ValueSemantics.atom,
        valueTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem heap_integer_eval_equation (state : InPlaceSemantics.State)
    (runtimeEnv : Env Value) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.atom (.int integer))).run state =
      (if depth = 0 then .error "in-place execution exhausted depth"
      else if state.fuel = 0 then .error "in-place execution exhausted fuel"
      else do
        let (_, post) ← InPlaceSemantics.observeKept.run (heapTicked state)
        pure (.int integer, post)) := by
  by_cases noDepth : depth = 0
  · simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.bind, StateT.lift, throw, throwThe, MonadExceptOf.throw, Except.map] <;> rfl
  · by_cases noFuel : state.fuel = 0
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, InPlaceSemantics.atom,
        noDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
        StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    · simp [InPlaceSemantics.eval, InPlaceSemantics.tick, InPlaceSemantics.atom,
        heapTicked, noDepth, noFuel, StateT.run, StateT.bind, StateT.get,
        StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-- The actual successful default inference run supplies its scalar result
and unchanged checker facts. The post-state equality is a conclusion of the
run, not an extra premise. The live-scope check still executes. -/
theorem infer_integer_success
    {ctx : Context}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.atom (.int integer)) after site).run before =
      .ok (result, next)) :
    result = .scalar ∧ next = before := by
  cases inferenceFuel with
  | zero =>
    simp [inferExpr, bridgeObserve, defaultConfig, Config.has,
      StateT.run, StateT.bind, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ fuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts,
        abstractAtom, scope, StateT.run, StateT.bind, StateT.map,
        StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
    | ok unit =>
      have computation :
          (inferExpr (fuel + 1) ctx aenv (.atom (.int integer)) after site).run before =
            .ok (.scalar, before) := by
        simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts,
          abstractAtom, scope, StateT.run, StateT.bind, StateT.map,
          StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
      rw [computation] at accepted
      have equal := Except.ok.inj accepted
      exact ⟨(congrArg Prod.fst equal).symm, (congrArg Prod.snd equal).symm⟩

/-- Both real evaluations succeed when their independent runtime bounds
permit the expression tick. Permanent observers need not be empty. -/
theorem integer_atom_runtime_success
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (hasDepth : depth ≠ 0) (hasFuel : vs.fuel ≠ 0) :
    (ValueSemantics.eval depth declarations none (Soundness.valueEnv env)
      (.atom (.int integer))).run vs = .ok (.int integer, valueAtomPost vs) ∧
    (InPlaceSemantics.eval depth declarations none (Soundness.heapEnv env)
      (.atom (.int integer))).run hs = .ok (.int integer, heapAtomPost hs vs.kept.toList) ∧
    FlatInvariant declarations (valueAtomPost vs) (heapAtomPost hs vs.kept.toList)
      env live aenv tenv escapes gamma := by
  obtain ⟨footprint, represented⟩ := inv.observers
  have valueObservedRun := value_observeKept_run (valueTicked vs) represented
  have heapObservedRun := heap_observeKept_run (heapTicked hs) represented
  have heapFuel : hs.fuel ≠ 0 := by simpa only [← inv.fuel] using hasFuel
  refine ⟨?_, ?_, integer_atom_post_invariant inv⟩
  · rw [value_integer_eval_equation]
    simp [hasDepth, hasFuel, valueObservedRun, valueAtomPost, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
  · rw [heap_integer_eval_equation]
    simp [hasDepth, heapFuel, heapObservedRun, heapAtomPost, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

/-- The complete observer witness excludes a later epilogue failure.
Thus a failed integer expression exhausts depth or fuel, and the other
interpreter also fails. The two error strings need not agree. -/
theorem integer_atom_failure
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (failed : (ValueSemantics.eval depth declarations none (Soundness.valueEnv env)
      (.atom (.int integer))).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (Soundness.heapEnv env)
        (.atom (.int integer))).run hs = .error actualMessage := by
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_integer_eval_equation]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_integer_eval_equation]
        simp [noDepth, heapFuel]⟩
    · have success := (integer_atom_runtime_success (integer := integer) inv noDepth noFuel).1
      rw [success] at failed
      contradiction

/-- The integer atom is a complete expression case under the strengthened
generic relation and the actual successful default inference equation.
The theorem constructs both runtime post-states and retains failure matching.
-/
theorem integer_atom_preserved
    {ctx : Context} {before : St}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.atom (.int integer)) after site).run before =
      .ok (result, next)) :
    result = .scalar ∧ next.facts = before.facts ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (Soundness.valueEnv env)
        (.atom (.int integer))).run vs = .ok (value, vs') →
      ∃ actual hs',
        (InPlaceSemantics.eval depth declarations none (Soundness.heapEnv env)
          (.atom (.int integer))).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma ∧
        Corresponds hs'.heap value actual ∧ Describes gamma hs'.heap result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (Soundness.valueEnv env)
        (.atom (.int integer))).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (Soundness.heapEnv env)
          (.atom (.int integer))).run hs = .error actualMessage) := by
  obtain ⟨scalar, checkerState⟩ := infer_integer_success defaultConfig accepted
  refine ⟨scalar, congrArg St.facts checkerState, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_integer_eval_equation] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_integer_eval_equation] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun, postInvariant⟩ :=
          integer_atom_runtime_success (integer := integer) inv noDepth noFuel
        rw [valueRun] at run
        cases run
        refine ⟨.int integer, heapAtomPost hs vs.kept.toList, heapRun, ?_,
          integer_corresponds integer, ?_⟩
        · simpa only [checkerState] using postInvariant
        · simpa only [scalar] using
            (integer_described (gamma := gamma)
              (heap := (heapAtomPost hs vs.kept.toList).heap) integer)
  · intro message failed
    exact integer_atom_failure inv failed

end Ownership.FlatFragment.AtomPreservation

/-! complete variable expression case under the generic flat relation.
A real accepted inference run supplies the abstract lookup. Prefix key
alignment supplies the runtime binding. The live root supplies correspondence.
No final interpreter agreement or separately checked permission is assumed.
-/

namespace Ownership.FlatFragment.VariablePreservation

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Env Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.AtomRuntime
open Ownership.FlatFragment.VariableRuntime Ownership.FlatFragment.AtomInference

theorem infer_variable_lookup {aenv : Env Abstract} {inferenceFuel : Nat} {key : Var} {before : St} {next : St} {ctx : Context} {after : Live} {site : List Nat} {result : Abstract}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.atom (.var key)) after site).run before =
      .ok (result, next)) :
    aenv.lookup key = some result ∧ next = before := by
  obtain ⟨lookupRun, checkerState⟩ := infer_atom_success defaultConfig accepted
  refine ⟨?_, checkerState⟩
  change lookup aenv key = .ok result at lookupRun
  cases found : aenv.lookup key with
  | none => simp [lookup, found] at lookupRun
  | some abstract =>
    have equal : abstract = result := by simpa [lookup, found] using lookupRun
    exact congrArg some equal

theorem variable_atom_failure {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {key : Var} {observation : Observation} {actual : Value} {before : St}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (binding : env.lookup key = some (observation, actual))
    (failed : (ValueSemantics.eval depth declarations none (valueEnv env)
      (.atom (.var key))).run vs = .error message) :
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env)
        (.atom (.var key))).run hs = .error actualMessage := by
  obtain ⟨_, heapAtom⟩ := variable_atoms_run binding
  by_cases noDepth : depth = 0
  · exact ⟨"in-place execution exhausted depth", by
      rw [heap_atom_eval_equation hs (heapEnv env) heapAtom]
      simp [noDepth]⟩
  · by_cases noFuel : vs.fuel = 0
    · have heapFuel : hs.fuel = 0 := inv.fuel.symm.trans noFuel
      exact ⟨"in-place execution exhausted fuel", by
        rw [heap_atom_eval_equation hs (heapEnv env) heapAtom]
        simp [noDepth, heapFuel]⟩
    · have success := (variable_runtime_success inv binding noDepth noFuel).1
      rw [success] at failed
      contradiction

theorem variable_atom_preserved {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {depth : Nat} {inferenceFuel : Nat} {key : Var} {before : St} {next : St} {ctx : Context} {after : Live} {site : List Nat} {result : Abstract}
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (use : (key, []) ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.atom (.var key)) after site).run before =
      .ok (result, next)) :
    next.facts = before.facts ∧
    (∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.atom (.var key))).run vs = .ok (value, vs') →
      ∃ actual hs',
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.atom (.var key))).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env live aenv tenv next.facts.escapes gamma ∧
        Corresponds hs'.heap value actual ∧ Describes gamma hs'.heap result actual) ∧
    (∀ message,
      (ValueSemantics.eval depth declarations none (valueEnv env)
        (.atom (.var key))).run vs = .error message →
      ∃ actualMessage,
        (InPlaceSemantics.eval depth declarations none (heapEnv env)
          (.atom (.var key))).run hs = .error actualMessage) := by
  obtain ⟨abstractBinding, checkerState⟩ := infer_variable_lookup defaultConfig accepted
  obtain ⟨observation, actual, binding⟩ := runtime_binding_of_abstract inv abstractBinding
  obtain ⟨valueAtom, _⟩ := variable_atoms_run binding
  refine ⟨congrArg St.facts checkerState, ?_, ?_⟩
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_atom_eval_equation vs (valueEnv env) valueAtom] at run
      simp [noDepth] at run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_atom_eval_equation vs (valueEnv env) valueAtom] at run
        simp [noDepth, noFuel] at run
      · obtain ⟨valueRun, heapRun, postInvariant⟩ :=
          variable_runtime_success inv binding noDepth noFuel
        rw [valueRun] at run
        cases run
        have correct := variable_post_correspondence inv use binding abstractBinding
        refine ⟨actual, heapAtomPost hs vs.kept.toList, heapRun, ?_, correct.1, correct.2⟩
        simpa only [checkerState] using postInvariant
  · intro message failed
    exact variable_atom_failure inv binding failed

end Ownership.FlatFragment.VariablePreservation
