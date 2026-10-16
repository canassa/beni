import Ownership.FlatFragment.Static

/-! The first flat fragment: binding and dropping a let, the let evaluation equations, and the let case. -/

/-! let composition under the generic flat relation.
A let binds the right-hand side's result for its continuation and drops it
afterwards. The binder is fresh by the real shadow check, so the outer
continuation has no use of it. Both runtimes tick, run both children at the
smaller depth, and observe. The induction hypotheses are explicit premises.
No final interpreter agreement or separate permission predicate is assumed.
-/

namespace Ownership.FlatFragment.Let

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.StateFrame
open Ownership.FlatFragment.Observe Ownership.FlatFragment.Runtime Ownership.FlatFragment.HeapPreservation Ownership.FlatFragment.Description
open Ownership.FlatFragment.Atoms Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferLet
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.LiveSets Ownership.FlatFragment.Liveness Ownership.FlatFragment.Scope
open Ownership.FlatFragment.HeapFrame Ownership.FlatFragment.Support Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.VariableFacts
open Ownership.FlatFragment.Static

/-! ### The contract of one preserved expression -/

/-- Both runtime directions of one expression, from paired states that the
relation connects, to paired states that it connects on the continuation. -/
structure Preserved (declarations : List Decl) (depth : Nat)
    (env : List (Var × Observation × Value)) (vs : ValueSemantics.State) (hs : State)
    (e : Expr) (after : Live) (aenv : Env Abstract) (tenv : Env Ty)
    (escapes' : List Origin) (result : Abstract) (type : Ty) : Prop where
  success : ∀ value vs',
    (ValueSemantics.eval depth declarations none (valueEnv env) e).run vs = .ok (value, vs') →
    ∃ actual hs' gamma',
      (InPlaceSemantics.eval depth declarations none (heapEnv env) e).run hs = .ok (actual, hs') ∧
      FlatInvariant declarations vs' hs' env after aenv tenv escapes' gamma' ∧
      hs.heap.size ≤ hs'.heap.size ∧
      Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
      obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type
  failure : ∀ message,
    (ValueSemantics.eval depth declarations none (valueEnv env) e).run vs = .error message →
    ∃ actualMessage,
      (InPlaceSemantics.eval depth declarations none (heapEnv env) e).run hs = .error actualMessage

/-! ### State lemmas -/

theorem ticked_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    FlatInvariant declarations (valueTicked vs) (heapTicked hs) env live aenv tenv escapes gamma :=
  flatInvariant_state_frame inv rfl rfl rfl rfl inv.reads inv.external
    (by simp [valueTicked, heapTicked, inv.fuel])

theorem observed_invariant {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    FlatInvariant declarations (valueObserved vs) (heapObserved hs vs.kept.toList)
      env live aenv tenv escapes gamma :=
  flatInvariant_state_frame inv (heapObserved_heap _ _) (heapObserved_links _ _)
    (valueObserved_kept _) (heapObserved_kept _ _)
    (by rw [valueObserved_reads, heapObserved_reads]; exact inv.reads)
    (observed_external vs hs inv.keptSize inv.external)
    (by rw [valueObserved_fuel, heapObserved_fuel]; exact inv.fuel)

/-- Binding the right-hand side's result. The new live set uses the binder
only at the empty path; every other use was live after the right-hand side. -/
theorem flatInvariant_bind {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {live' : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin} {v : Var} {x : Observation} {w : Value} {a : Abstract} {ty : Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (fresh : v ∉ env.map Prod.fst)
    (paired : Corresponds hs.heap x w) (described : Describes gamma hs.heap a w)
    (flatType : FlatType ty) (flatAbstract : FlatAbstract ty a)
    (observed : obsTyped declarations x ty = true)
    (valueTyped : ValueTyped declarations hs.heap w ty)
    (liveSub : ∀ use ∈ live', use.1 = v ∨ use ∈ live)
    (liveFlat : ∀ p, (v, p) ∈ live' → p = []) :
    FlatInvariant declarations vs hs ((v, x, w) :: env) live' ((v, a) :: aenv) ((v, ty) :: tenv)
      escapes gamma := by
  have shape := allocated_shape_of_typed flatType valueTyped
  refine {
    toInvariant := {
      reads := inv.reads
      external := inv.external
      fuel := inv.fuel
      keptSize := inv.keptSize
      kept := inv.kept
      keptEscaped := inv.keptEscaped
      bindings := ?_
      described := ?_
      named := ?_
      separating := inv.separating
      linksValid := Soundness.linksValid_of_empty _ (inv.links)
      linkNamed := Soundness.linkNamed_of_empty _ _ _ _ (inv.links)
    }
    heapInts := inv.heapInts
    links := inv.links
    abstractKeys := by simp [inv.abstractKeys]
    typeKeys := by simp [inv.typeKeys]
    types := ?_
    abstractShapes := ?_
    bindingsTyped := ?_
    namingBound := inv.namingBound
    observers := inv.observers
  }
  · intro key p use o w' binding
    by_cases same : key = v
    · subst same
      have pathNil := liveFlat p use
      subst pathNil
      rw [lookup_cons_same] at binding
      cases Option.some.inj binding
      exact ⟨x, w, rfl, rfl, paired⟩
    · rw [lookup_cons_other _ _ _ same] at binding
      rcases liveSub _ use with equal | old
      · exact absurd equal same
      · exact inv.bindings key p old o w' binding
  · intro key p use o w' a' w'' binding abstractBinding valuePath
    by_cases same : key = v
    · subst same
      have pathNil := liveFlat p use
      subst pathNil
      rw [lookup_cons_same] at binding abstractBinding
      cases Option.some.inj binding
      cases Option.some.inj abstractBinding
      cases Option.some.inj valuePath
      simpa only [Abstract.atPath] using described
    · rw [lookup_cons_other _ _ _ same] at binding abstractBinding
      rcases liveSub _ use with equal | old
      · exact absurd equal same
      · exact inv.described key p old o w' a' w'' binding abstractBinding valuePath
  · intro key o w' a' binding abstractBinding q c immutable located
    by_cases same : key = v
    · subst same
      rw [lookup_cons_same] at binding abstractBinding
      cases Option.some.inj binding
      cases Option.some.inj abstractBinding
      cases shape with
      | int integer => cases located
      | list root allocated =>
        have lookupRoot : hs.heap[root]? = some hs.heap[root] := by simp [allocated]
        obtain ⟨integers, payload⟩ :=
          integers_of_flat_values hs.heap[root] (inv.heapInts root _ lookupRoot)
        rw [payload] at lookupRoot
        obtain ⟨pathNil, sameRoot⟩ := arrayAt_flat_ref lookupRoot located
        subst pathNil
        rw [sameRoot]
        have covered := described.1.1 [] root (.here _)
        simpa only [namesAt] using covered
    · rw [lookup_cons_other _ _ _ same] at binding abstractBinding
      exact inv.named key o w' a' binding abstractBinding q c immutable located
  · intro key ty' declared
    by_cases same : key = v
    · subst same
      rw [lookup_cons_same] at declared
      cases Option.some.inj declared
      exact flatType
    · rw [lookup_cons_other _ _ _ same] at declared
      exact inv.types key ty' declared
  · intro key ty' a' declared abstractBinding
    by_cases same : key = v
    · subst same
      rw [lookup_cons_same] at declared abstractBinding
      cases Option.some.inj declared
      cases Option.some.inj abstractBinding
      exact flatAbstract
    · rw [lookup_cons_other _ _ _ same] at declared abstractBinding
      exact inv.abstractShapes key ty' a' declared abstractBinding
  · intro key o w' binding
    by_cases same : key = v
    · subst same
      rw [lookup_cons_same] at binding
      cases Option.some.inj binding
      exact ⟨ty, lookup_cons_same _ _ _, observed, valueTyped⟩
    · rw [lookup_cons_other _ _ _ same] at binding
      obtain ⟨ty', declared, observed', typed'⟩ := inv.bindingsTyped key o w' binding
      exact ⟨ty', by rw [lookup_cons_other _ _ _ same]; exact declared, observed', typed'⟩

/-- Dropping the binder after its continuation. The live set has no use of
the binder, and the binder is fresh in the outer environment. -/
theorem flatInvariant_unbind {declarations : List Decl} {vs : ValueSemantics.State} {hs : State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {gamma : Naming} {escapes : List Origin} {v : Var} {x : Observation} {w : Value} {a : Abstract} {ty : Ty}
    (inv : FlatInvariant declarations vs hs ((v, x, w) :: env) live ((v, a) :: aenv) ((v, ty) :: tenv)
      escapes gamma)
    (fresh : v ∉ env.map Prod.fst)
    (noUse : ∀ use ∈ live, use.1 ≠ v) :
    FlatInvariant declarations vs hs env live aenv tenv escapes gamma := by
  have abstractKeys : env.map Prod.fst = aenv.map Prod.fst := by
    have keys := inv.abstractKeys
    simp only [List.map_cons, List.cons.injEq] at keys
    exact keys.2
  have typeKeys : env.map Prod.fst = tenv.map Prod.fst := by
    have keys := inv.typeKeys
    simp only [List.map_cons, List.cons.injEq] at keys
    exact keys.2
  have envOther : ∀ key (pair : Observation × Value), env.lookup key = some pair → key ≠ v := by
    intro key pair binding same
    subst same
    exact fresh (lookup_key_member binding)
  have tenvOther : ∀ key ty', tenv.lookup key = some ty' → key ≠ v := by
    intro key ty' declared same
    subst same
    have member := lookup_key_member declared
    rw [← typeKeys] at member
    exact fresh member
  refine {
    toInvariant := {
      reads := inv.reads
      external := inv.external
      fuel := inv.fuel
      keptSize := inv.keptSize
      kept := inv.kept
      keptEscaped := inv.keptEscaped
      bindings := ?_
      described := ?_
      named := ?_
      separating := inv.separating
      linksValid := Soundness.linksValid_of_empty _ (inv.links)
      linkNamed := Soundness.linkNamed_of_empty _ _ _ _ (inv.links)
    }
    heapInts := inv.heapInts
    links := inv.links
    abstractKeys := abstractKeys
    typeKeys := typeKeys
    types := ?_
    abstractShapes := ?_
    bindingsTyped := ?_
    namingBound := inv.namingBound
    observers := inv.observers
  }
  · intro key p use o w' binding
    have different := noUse _ use
    exact inv.bindings key p use o w' (by rw [lookup_cons_other _ _ _ different]; exact binding)
  · intro key p use o w' a' w'' binding abstractBinding valuePath
    have different := noUse _ use
    exact inv.described key p use o w' a' w''
      (by rw [lookup_cons_other _ _ _ different]; exact binding)
      (by rw [lookup_cons_other _ _ _ different]; exact abstractBinding) valuePath
  · intro key o w' a' binding abstractBinding q c immutable located
    have different := envOther key _ binding
    exact inv.named key o w' a'
      (by rw [lookup_cons_other _ _ _ different]; exact binding)
      (by rw [lookup_cons_other _ _ _ different]; exact abstractBinding) q c immutable located
  · intro key ty' declared
    have different := tenvOther key ty' declared
    exact inv.types key ty' (by rw [lookup_cons_other _ _ _ different]; exact declared)
  · intro key ty' a' declared abstractBinding
    have different := tenvOther key ty' declared
    exact inv.abstractShapes key ty' a'
      (by rw [lookup_cons_other _ _ _ different]; exact declared)
      (by rw [lookup_cons_other _ _ _ different]; exact abstractBinding)
  · intro key o w' binding
    have different := envOther key _ binding
    obtain ⟨ty', declared, observed, typed⟩ :=
      inv.bindingsTyped key o w' (by rw [lookup_cons_other _ _ _ different]; exact binding)
    rw [lookup_cons_other _ _ _ different] at declared
    exact ⟨ty', declared, observed, typed⟩

/-! ### The runtime let equations -/

theorem value_let_depth {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} (s : ValueSemantics.State) (runtimeEnv : Env Observation)
    (noDepth : depth = 0) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run s =
      .error "value execution exhausted depth" := by
  simp [ValueSemantics.eval, noDepth, StateT.run, StateT.lift, throw, throwThe, MonadExceptOf.throw] <;> rfl

theorem value_let_fuel {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} (s : ValueSemantics.State) (runtimeEnv : Env Observation)
    (hasDepth : depth ≠ 0) (noFuel : s.fuel = 0) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run s =
      .error "value execution exhausted fuel" := by
  rw [ValueSemantics.eval]
  simp [ValueSemantics.tick, hasDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
    MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem value_let_rhs_error {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} {message : String} (s : ValueSemantics.State) (runtimeEnv : Env Observation)
    (hasDepth : depth ≠ 0) (hasFuel : s.fuel ≠ 0)
    (rhsError : (ValueSemantics.eval (depth - 1) declarations none runtimeEnv rhs).run
      {s with fuel := s.fuel - 1} = .error message) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run s =
      .error message := by
  have rhsError' : ValueSemantics.eval (depth - 1) declarations none runtimeEnv rhs
      {s with fuel := s.fuel - 1} = .error message := rhsError
  rw [ValueSemantics.eval]
  simp [ValueSemantics.tick, hasDepth, hasFuel, rhsError', StateT.run, StateT.bind, StateT.get,
    StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
    MonadExceptOf.throw]

theorem value_let_rhs_ok {declarations : List Decl} {depth : Nat} {v : Var} {x : Observation} {rhs : Expr} {rest : Expr} {s1 : ValueSemantics.State} (s : ValueSemantics.State) (runtimeEnv : Env Observation)
    (hasDepth : depth ≠ 0) (hasFuel : s.fuel ≠ 0)
    (rhsOk : (ValueSemantics.eval (depth - 1) declarations none runtimeEnv rhs).run
      {s with fuel := s.fuel - 1} = .ok (x, s1)) :
    (ValueSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run s =
      (do
        let (y, s2) ← (ValueSemantics.eval (depth - 1) declarations none ((v, x) :: runtimeEnv) rest).run s1
        let (_, s3) ← ValueSemantics.observeKept.run s2
        pure (y, s3)) := by
  have rhsOk' : ValueSemantics.eval (depth - 1) declarations none runtimeEnv rhs
      {s with fuel := s.fuel - 1} = .ok (x, s1) := rhsOk
  rw [ValueSemantics.eval]
  simp [ValueSemantics.tick, hasDepth, hasFuel, rhsOk', StateT.run, StateT.bind, StateT.get,
    StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
    MonadExceptOf.throw]

theorem heap_let_depth {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} (hsa : State) (runtimeEnv : Env Value) (noDepth : depth = 0) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run hsa =
      .error "in-place execution exhausted depth" := by
  simp [InPlaceSemantics.eval, noDepth, StateT.run, StateT.lift, throw, throwThe, MonadExceptOf.throw] <;> rfl

theorem heap_let_fuel {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} (hsa : State) (runtimeEnv : Env Value)
    (hasDepth : depth ≠ 0) (noFuel : hsa.fuel = 0) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run hsa =
      .error "in-place execution exhausted fuel" := by
  rw [InPlaceSemantics.eval]
  simp [InPlaceSemantics.tick, hasDepth, noFuel, StateT.run, StateT.bind, StateT.get, StateT.set,
    StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
    MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]

theorem heap_let_rhs_error {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} {message : String} (hsa : State) (runtimeEnv : Env Value)
    (hasDepth : depth ≠ 0) (hasFuel : hsa.fuel ≠ 0)
    (rhsError : (InPlaceSemantics.eval (depth - 1) declarations none runtimeEnv rhs).run
      {hsa with fuel := hsa.fuel - 1} = .error message) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run hsa =
      .error message := by
  have rhsError' : InPlaceSemantics.eval (depth - 1) declarations none runtimeEnv rhs
      {hsa with fuel := hsa.fuel - 1} = .error message := rhsError
  rw [InPlaceSemantics.eval]
  simp [InPlaceSemantics.tick, hasDepth, hasFuel, rhsError', StateT.run, StateT.bind, StateT.get,
    StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
    MonadExceptOf.throw]

theorem heap_let_rhs_ok {declarations : List Decl} {depth : Nat} {v : Var} {rhs : Expr} {rest : Expr} {hsb : State} {wa : Value} (hsa : State) (runtimeEnv : Env Value)
    (hasDepth : depth ≠ 0) (hasFuel : hsa.fuel ≠ 0)
    (rhsOk : (InPlaceSemantics.eval (depth - 1) declarations none runtimeEnv rhs).run
      {hsa with fuel := hsa.fuel - 1} = .ok (wa, hsb)) :
    (InPlaceSemantics.eval depth declarations none runtimeEnv (.letE v rhs rest)).run hsa =
      (do
        let (y, s2) ← (InPlaceSemantics.eval (depth - 1) declarations none ((v, wa) :: runtimeEnv) rest).run hsb
        let (_, s3) ← InPlaceSemantics.observeKept.run s2
        pure (y, s3)) := by
  have rhsOk' : InPlaceSemantics.eval (depth - 1) declarations none runtimeEnv rhs
      {hsa with fuel := hsa.fuel - 1} = .ok (wa, hsb) := rhsOk
  rw [InPlaceSemantics.eval]
  simp [InPlaceSemantics.tick, hasDepth, hasFuel, rhsOk', StateT.run, StateT.bind, StateT.get,
    StateT.set, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
    MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
    MonadExceptOf.throw]

/-! ### The let case -/

theorem uses_let (v : Var) (rhs rest : Expr) :
    uses (.letE v rhs rest) = union (uses rhs) (removeVars [v] (uses rest)) := rfl

theorem let_preserved {declarations : List Decl} {v : Var} {rhs : Expr} {rest : Expr}
    {self : Decl} {ctx : Context} {inferenceFuel : Nat} {after : Live} {site : List Nat}
    {before next : St} {result : Abstract} {type : Ty} {bound : List Var}
    (flatRhs : FlatANF0 rhs) (flatRest : FlatANF0 rest)
    (ihRhs : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv rhs = .ok type → shadowFree bound rhs = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses rhs, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv rhs after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs rhs after aenv tenv next.facts.escapes result type)
    (ihRest : ∀ (vs : ValueSemantics.State) (hs : State) (env : List (Var × Observation × Value))
      (live : Live) (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (gamma : Naming)
      (type : Ty) (bound : List Var) (after : Live) (site : List Nat) (result : Abstract)
      (inferenceFuel depth : Nat) (ctx : Context),
      FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma →
      exprType declarations self tenv rest = .ok type → shadowFree bound rest = .ok () →
      (∀ x ∈ env.map Prod.fst, x ∈ bound) → (∀ use ∈ uses rest, use ∈ live) →
      (∀ use ∈ after, use ∈ live) → ctx.config = {} →
      (inferExpr inferenceFuel ctx aenv rest after site).run before = .ok (result, next) →
      Preserved declarations depth env vs hs rest after aenv tenv next.facts.escapes result type)
    (inv : FlatInvariant declarations vs hs env live aenv tenv before.facts.escapes gamma)
    (typed : exprType declarations self tenv (.letE v rhs rest) = .ok type)
    (shadow : shadowFree bound (.letE v rhs rest) = .ok ())
    (boundKeys : ∀ x ∈ env.map Prod.fst, x ∈ bound)
    (usesLive : ∀ use ∈ uses (.letE v rhs rest), use ∈ live)
    (afterSub : ∀ use ∈ after, use ∈ live)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.letE v rhs rest) after site).run before =
      .ok (result, next)) :
    Preserved declarations depth env vs hs (.letE v rhs rest) after aenv tenv next.facts.escapes
      result type := by
  -- Static facts.
  obtain ⟨rhsType, rhsTyped, restTyped⟩ := exprType_let_success typed
  obtain ⟨_, binderFresh, rhsShadow, restShadow⟩ := shadowFree_let_success shadow
  have fresh : v ∉ env.map Prod.fst := fun member => binderFresh (boundKeys v member)
  have scope := infer_scope_success defaultConfig accepted
  have outerEmpty := outer_avoids_fresh_binder inv.abstractKeys fresh scope
  have noUse : ∀ use ∈ after, use.1 ≠ v := by
    intro use member same
    have excluded := List.filter_eq_nil_iff.mp outerEmpty use member
    simp [same] at excluded
  obtain ⟨childFuel, a, middle, _, _, rhsRun, restRun⟩ :=
    infer_let_success defaultConfig outerEmpty accepted
  have restUses : usesWith ctx.config rest = uses rest := by
    rw [defaultConfig]; exact flatExpr_default_uses flatRest
  rw [restUses] at rhsRun
  rw [uses_let] at usesLive
  have rhsUsesLive : ∀ use ∈ uses rhs, use ∈ live :=
    fun use member => usesLive use (union_left _ _ use member)
  have rhsAfterSub : ∀ use ∈ union after (removeVars [v] (uses rest)), use ∈ live := by
    intro use member
    rcases mem_union_cases _ _ use member with outer | continuation
    · exact afterSub use outer
    · exact usesLive use (union_right _ _ use continuation)
  have static := FlatStatic.of_invariant inv
  have aenvBound : ∀ x ∈ aenv.map Prod.fst, x ∈ bound := by
    rw [← inv.abstractKeys]; exact boundKeys
  obtain ⟨rhsFlatType, rhsFlatAbstract, _⟩ :=
    flat_static (self := self) flatRhs aenv tenv before middle rhsType bound _ (site ++ [0]) a
      childFuel _ static rhsTyped rhsShadow aenvBound (by exact defaultConfig) rhsRun
  have rhsPreserved := ihRhs (valueTicked vs) (heapTicked hs) env live aenv tenv before middle gamma
    rhsType bound (union after (removeVars [v] (uses rest))) (site ++ [0]) a childFuel (depth - 1) _
    (ticked_invariant inv) rhsTyped rhsShadow boundKeys rhsUsesLive rhsAfterSub (by exact defaultConfig) rhsRun
  have restLiveSub : ∀ use ∈ union (uses rest) after,
      use.1 = v ∨ use ∈ union after (removeVars [v] (uses rest)) := by
    intro use member
    by_cases same : use.1 = v
    · exact Or.inl same
    · exact Or.inr (continuation_old_live v (uses rest) after same member)
  have restLiveFlat : ∀ p, (v, p) ∈ union (uses rest) after → p = [] := by
    intro p member
    rcases mem_union_cases _ _ (v, p) member with inner | outer
    · exact flatExpr_uses flatRest v p inner
    · exact absurd rfl (noUse (v, p) outer)
  have restUsesLive : ∀ use ∈ uses rest, use ∈ union (uses rest) after :=
    fun use member => union_left _ _ use member
  have restAfterSub : ∀ use ∈ after, use ∈ union (uses rest) after :=
    fun use member => union_right _ _ use member
  have restBoundKeys : ∀ (x : Observation) (w : Value),
      ∀ key ∈ ((v, x, w) :: env).map Prod.fst, key ∈ v :: bound := by
    intro x w key member
    simp only [List.map_cons, List.mem_cons] at member
    rcases member with rfl | old
    · simp
    · exact List.mem_cons_of_mem _ (boundKeys key old)
  have heapFuelEq : hs.fuel = vs.fuel := inv.fuel.symm
  constructor
  · intro value vs' run
    by_cases noDepth : depth = 0
    · rw [value_let_depth vs (valueEnv env) noDepth] at run
      cases run
    · by_cases noFuel : vs.fuel = 0
      · rw [value_let_fuel vs (valueEnv env) noDepth noFuel] at run
        cases run
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        cases rhsValue : (ValueSemantics.eval (depth - 1) declarations none (valueEnv env) rhs).run
            {vs with fuel := vs.fuel - 1} with
        | error m1 =>
          rw [value_let_rhs_error vs (valueEnv env) noDepth noFuel rhsValue] at run
          cases run
        | ok p1 =>
          rcases p1 with ⟨x, s1⟩
          rw [value_let_rhs_ok vs (valueEnv env) noDepth noFuel rhsValue] at run
          obtain ⟨w, hs1, gamma1, rhsHeapRun, inv1, size1, paired1, described1, observed1, typed1⟩ :=
            rhsPreserved.success x s1 rhsValue
          have inv1' := flatInvariant_bind inv1 fresh paired1 described1 rhsFlatType rhsFlatAbstract
            observed1 typed1 restLiveSub restLiveFlat
          have restPreserved := ihRest s1 hs1 ((v, x, w) :: env) (union (uses rest) after)
            ((v, a) :: aenv) ((v, rhsType) :: tenv) middle next gamma1 type (v :: bound) after
            (site ++ [1]) result childFuel (depth - 1) _ inv1' restTyped restShadow
            (restBoundKeys x w) restUsesLive restAfterSub (by exact defaultConfig) restRun
          obtain ⟨p2, restValueRun, run⟩ := except_bind_success run
          rcases p2 with ⟨y, s2⟩
          obtain ⟨actual, hs2, gamma2, restHeapRun, inv2, size2, paired2, described2, observed2, typed2⟩ :=
            restPreserved.success y s2 restValueRun
          have restHeapRun' : (InPlaceSemantics.eval (depth - 1) declarations none
              ((v, w) :: heapEnv env) rest).run hs1 = .ok (actual, hs2) := restHeapRun
          try dsimp only at run
          obtain ⟨p3, observeRun, run⟩ := except_bind_success run
          rcases p3 with ⟨u, s3⟩
          try dsimp only at run
          have final : (y, s3) = (value, vs') := Except.ok.inj run
          obtain ⟨footprint2, represented2⟩ := inv2.observers
          have valueObserveRun := value_observeKept_run s2 represented2
          rw [valueObserveRun] at observeRun
          have observeEq : ((), valueObserved s2) = (u, s3) := Except.ok.inj observeRun
          have heapObserveRun := heap_observeKept_run hs2 represented2
          have inv3 := observed_invariant (flatInvariant_unbind inv2 fresh noUse)
          have s3Eq : s3 = vs' := congrArg Prod.snd final
          have observed3 : valueObserved s2 = s3 := congrArg Prod.snd observeEq
          have vsEq : vs' = valueObserved s2 := s3Eq.symm.trans observed3.symm
          have valueEq : value = y := (congrArg Prod.fst final).symm
          subst vsEq
          subst valueEq
          refine ⟨actual, heapObserved hs2 s2.kept.toList, gamma2, ?_, inv3, ?_, ?_, ?_,
            observed2, ?_⟩
          · rw [heap_let_rhs_ok hs (heapEnv env) noDepth heapFuel rhsHeapRun]
            simp [restHeapRun', heapObserveRun, Except.bind, Except.pure, bind, pure]
          · rw [heapObserved_heap]
            exact Nat.le_trans size1 size2
          · rw [heapObserved_heap]; exact paired2
          · rw [heapObserved_heap]; exact described2
          · rw [heapObserved_heap]; exact typed2
  · intro message run
    by_cases noDepth : depth = 0
    · exact ⟨"in-place execution exhausted depth", heap_let_depth hs (heapEnv env) noDepth⟩
    · by_cases noFuel : vs.fuel = 0
      · have heapFuel : hs.fuel = 0 := by rw [heapFuelEq]; exact noFuel
        exact ⟨"in-place execution exhausted fuel", heap_let_fuel hs (heapEnv env) noDepth heapFuel⟩
      · have heapFuel : hs.fuel ≠ 0 := by rw [heapFuelEq]; exact noFuel
        cases rhsValue : (ValueSemantics.eval (depth - 1) declarations none (valueEnv env) rhs).run
            {vs with fuel := vs.fuel - 1} with
        | error m1 =>
          obtain ⟨m1', rhsHeapError⟩ := rhsPreserved.failure m1 rhsValue
          exact ⟨m1', heap_let_rhs_error hs (heapEnv env) noDepth heapFuel rhsHeapError⟩
        | ok p1 =>
          rcases p1 with ⟨x, s1⟩
          rw [value_let_rhs_ok vs (valueEnv env) noDepth noFuel rhsValue] at run
          obtain ⟨w, hs1, gamma1, rhsHeapRun, inv1, _, paired1, described1, observed1, typed1⟩ :=
            rhsPreserved.success x s1 rhsValue
          have inv1' := flatInvariant_bind inv1 fresh paired1 described1 rhsFlatType rhsFlatAbstract
            observed1 typed1 restLiveSub restLiveFlat
          have restPreserved := ihRest s1 hs1 ((v, x, w) :: env) (union (uses rest) after)
            ((v, a) :: aenv) ((v, rhsType) :: tenv) middle next gamma1 type (v :: bound) after
            (site ++ [1]) result childFuel (depth - 1) _ inv1' restTyped restShadow
            (restBoundKeys x w) restUsesLive restAfterSub (by exact defaultConfig) restRun
          cases restValue : (ValueSemantics.eval (depth - 1) declarations none
              ((v, x) :: valueEnv env) rest).run s1 with
          | error m2 =>
            obtain ⟨m2', restHeapError⟩ := restPreserved.failure m2 restValue
            have restHeapError' : (InPlaceSemantics.eval (depth - 1) declarations none
                ((v, w) :: heapEnv env) rest).run hs1 = .error m2' := restHeapError
            exact ⟨m2', by
              rw [heap_let_rhs_ok hs (heapEnv env) noDepth heapFuel rhsHeapRun]
              simp [restHeapError', Except.bind, bind]⟩
          | ok p2 =>
            rcases p2 with ⟨y, s2⟩
            obtain ⟨actual, hs2, gamma2, _, inv2, _⟩ := restPreserved.success y s2 restValue
            obtain ⟨footprint2, represented2⟩ := inv2.observers
            have valueObserveRun := value_observeKept_run s2 represented2
            rw [restValue] at run
            simp only [bind, Except.bind] at run
            rw [valueObserveRun] at run
            simp [pure, Except.pure] at run

end Ownership.FlatFragment.Let
