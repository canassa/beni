import Ownership.FlatFragment.Primitives

/-! The first flat fragment: the static facts of an accepted expression. -/

/-! static facts of an accepted flat expression.
The result type is flat, the abstract result has the flat shape of that
type, and the recorded escapes only grow. These follow from the actual
typing and inference runs and the static part of the prefix relation. No
runtime state enters, so the let case can use them before its right-hand
side runs.
-/

namespace Ownership.FlatFragment.Static

open InPlaceSemantics Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Support Ownership.FlatFragment.Atoms
open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferLet Ownership.FlatFragment.Liveness Ownership.FlatFragment.Scope
open Ownership.FlatFragment.VariableFacts Ownership.FlatFragment.AtomInteger Ownership.FlatFragment.PrimitiveInference
open Ownership.FlatFragment.Literal Ownership.FlatFragment.Length Ownership.FlatFragment.Shared Ownership.FlatFragment.Push Ownership.FlatFragment.AtomInference

/-! ### Environment lookups -/

theorem lookup_cons_other {α : Type} (entry : Var × α) (rest : Env α) (key : Var)
    (different : key ≠ entry.1) : (entry :: rest).lookup key = rest.lookup key := by
  rcases entry with ⟨name, value⟩
  have different' : key ≠ name := different
  have beqFalse : (key == name) = false := by simpa using different'
  simp [List.lookup_cons, beqFalse]

theorem lookup_cons_same {α : Type} (name : Var) (value : α) (rest : Env α) :
    ((name, value) :: rest).lookup name = some value := by
  simp

/-- Any successful default inference ran the live-scope check first. -/
theorem infer_scope_success {aenv : Env Abstract} {ctx : Context} {inferenceFuel : Nat} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {e : Expr}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv e after site).run before = .ok (result, next)) :
    liveScope aenv after = .ok () := by
  cases inferenceFuel with
  | zero =>
    simp [inferExpr, bridgeObserve, defaultConfig, Config.has,
      StateT.run, StateT.bind, StateT.get, StateT.lift, Except.bind, Except.pure,
      StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set,
      liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ fuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      rw [inferExpr] at accepted
      simp [bridgeObserve, defaultConfig, Config.has, getFacts,
        scope, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift,
        Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
        MonadStateOf.get, MonadStateOf.set, liftM, monadLift,
        MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
    | ok unit => cases unit; rfl

/-! ### The static relation -/

/-- The static part of the prefix relation. -/
structure FlatStatic (aenv : Env Abstract) (tenv : Env Ty) : Prop where
  keys : aenv.map Prod.fst = tenv.map Prod.fst
  types : ∀ x ty, tenv.lookup x = some ty → FlatType ty
  shapes : ∀ x ty a, tenv.lookup x = some ty → aenv.lookup x = some a → FlatAbstract ty a

theorem FlatStatic.of_invariant {declarations : List Decl} {aenv : Env Abstract} {tenv : Env Ty}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    FlatStatic aenv tenv :=
  ⟨inv.abstractKeys.symm.trans inv.typeKeys, inv.types, inv.abstractShapes⟩

theorem FlatStatic.bind {aenv : Env Abstract} {tenv : Env Ty} {ty : Ty} {a : Abstract} (static : FlatStatic aenv tenv) (v : Var) (flatType : FlatType ty)
    (flatAbstract : FlatAbstract ty a) :
    FlatStatic ((v, a) :: aenv) ((v, ty) :: tenv) := by
  refine ⟨by simp [static.keys], ?_, ?_⟩
  · intro key ty' declared
    by_cases same : key = v
    · subst same
      rw [lookup_cons_same] at declared
      cases Option.some.inj declared
      exact flatType
    · rw [lookup_cons_other _ _ _ same] at declared
      exact static.types key ty' declared
  · intro key ty' a' declared abstractBinding
    by_cases same : key = v
    · subst same
      rw [lookup_cons_same] at declared abstractBinding
      cases Option.some.inj declared
      cases Option.some.inj abstractBinding
      exact flatAbstract
    · rw [lookup_cons_other _ _ _ same] at declared abstractBinding
      exact static.shapes key ty' a' declared abstractBinding

/-! ### Static atom facts -/

theorem static_atom_type {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {ty : Ty} (static : FlatStatic aenv tenv) (flat : FlatAtom atom)
    (typed : atomType tenv atom = .ok ty) : FlatType ty := by
  cases flat with
  | int _ =>
    change Except.ok Ty.int = Except.ok ty at typed
    cases Except.ok.inj typed
    exact .int
  | var key =>
    have typeRun : lookup tenv key = .ok ty := by simpa only [atomType] using typed
    exact static.types key ty (lookup_option_of_success typeRun)

theorem static_atom_abstract {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {ty : Ty} (static : FlatStatic aenv tenv) (flat : FlatAtom atom)
    (typed : atomType tenv atom = .ok ty) :
    ∃ abstract, abstractAtom aenv atom = .ok abstract ∧ FlatAbstract ty abstract := by
  cases flat with
  | int _ =>
    change Except.ok Ty.int = Except.ok ty at typed
    cases Except.ok.inj typed
    exact ⟨.scalar, rfl, .int⟩
  | var key =>
    have typeRun : lookup tenv key = .ok ty := by simpa only [atomType] using typed
    have declared := lookup_option_of_success typeRun
    obtain ⟨abstract, found⟩ := lookup_exists_of_same_keys aenv tenv static.keys declared
    exact ⟨abstract, by simp [abstractAtom, lookup, found], static.shapes key ty abstract declared found⟩

theorem static_atom_scalar {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} (static : FlatStatic aenv tenv) (flat : FlatAtom atom)
    (typed : atomType tenv atom = .ok .int) : abstractAtom aenv atom = .ok .scalar := by
  obtain ⟨abstract, run, shape⟩ := static_atom_abstract static flat typed
  cases shape
  exact run

theorem static_atom_list {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} (static : FlatStatic aenv tenv) (flat : FlatAtom atom)
    (typed : atomType tenv atom = .ok (.list .int)) :
    ∃ roots element certificate, abstractAtom aenv atom = .ok (.list roots element certificate) ∧
      (element = .bottom ∨ element = .scalar) := by
  obtain ⟨abstract, run, shape⟩ := static_atom_abstract static flat typed
  cases shape with
  | listBottom roots certificate => exact ⟨roots, .bottom, certificate, run, Or.inl rfl⟩
  | listScalar roots certificate => exact ⟨roots, .scalar, certificate, run, Or.inr rfl⟩

theorem static_atoms_scalar {aenv : Env Abstract} {tenv : Env Ty} {args : List Atom} {types : List Ty} (static : FlatStatic aenv tenv)
    (flat : ∀ atom ∈ args, FlatAtom atom)
    (typed : args.mapM (atomType tenv) = .ok types) (ints : ∀ ty ∈ types, ty = .int) :
    args.mapM (m := Except String) (abstractAtom aenv) = .ok (args.map fun _ => Abstract.scalar) := by
  induction args generalizing types with
  | nil => rfl
  | cons atom rest ih =>
    obtain ⟨headType, restTypes, headTyped, restTyped, shape⟩ := except_mapM_cons_success typed
    subst shape
    have headInt : headType = .int := ints headType (by simp)
    subst headInt
    exact except_mapM_cons (static_atom_scalar static (flat atom (by simp)) headTyped)
      (ih (fun atom member => flat atom (by simp [member])) restTyped
        (fun ty member => ints ty (by simp [member])))

theorem list_mapOrigins_flat (f : Path → List Origin → List Origin) (roots : List Origin)
    (element : Abstract) (certificate : Certificate)
    (flat : element = .bottom ∨ element = .scalar) :
    (Abstract.list roots element certificate).mapOrigins f [] = .list (f [] roots) element certificate := by
  rcases flat with rfl | rfl <;> simp [Abstract.mapOrigins]

/-! ### The static theorem -/

theorem flat_static {declarations : List Decl} {self : Decl} {e : Expr} (flat : FlatANF0 e) :
    ∀ (aenv : Env Abstract) (tenv : Env Ty) (before next : St) (type : Ty) (bound : List Var)
      (after : Live) (site : List Nat) (result : Abstract) (inferenceFuel : Nat) (ctx : Context),
    FlatStatic aenv tenv → exprType declarations self tenv e = .ok type →
    shadowFree bound e = .ok () → (∀ x ∈ aenv.map Prod.fst, x ∈ bound) → ctx.config = {} →
    (inferExpr inferenceFuel ctx aenv e after site).run before = .ok (result, next) →
    FlatType type ∧ FlatAbstract type result ∧
    (∀ origin, Escaped before.facts.escapes origin → Escaped next.facts.escapes origin) := by
  induction flat with
  | @atom a atomFlat =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨atomRun, checkerState⟩ := infer_atom_success defaultConfig accepted
    subst checkerState
    have atomTyped : atomType tenv a = .ok type := typed
    obtain ⟨abstract, run, shape⟩ := static_atom_abstract static atomFlat atomTyped
    rw [run] at atomRun
    cases Except.ok.inj atomRun
    exact ⟨static_atom_type static atomFlat atomTyped, shape, fun _ escaped => escaped⟩
  | @letE rhs rest v rhsFlat restFlat ihRhs ihRest =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed shadow boundKeys defaultConfig accepted
    obtain ⟨rhsType, rhsTyped, restTyped⟩ := exprType_let_success typed
    obtain ⟨_, binderFresh, rhsShadow, restShadow⟩ := shadowFree_let_success shadow
    have fresh : v ∉ aenv.map Prod.fst := fun member => binderFresh (boundKeys v member)
    have scope := infer_scope_success defaultConfig accepted
    have outerEmpty := outer_avoids_fresh_binder (env := aenv) rfl fresh scope
    obtain ⟨childFuel, a, middle, _, _, rhsRun, restRun⟩ :=
      infer_let_success defaultConfig outerEmpty accepted
    obtain ⟨rhsFlatType, rhsFlatAbstract, rhsMono⟩ :=
      ihRhs aenv tenv before middle rhsType bound _ (site ++ [0]) a childFuel _
        static rhsTyped rhsShadow boundKeys (by exact defaultConfig) rhsRun
    have restBoundKeys : ∀ x ∈ ((v, a) :: aenv).map Prod.fst, x ∈ v :: bound := by
      intro x member
      simp only [List.map_cons, List.mem_cons] at member
      rcases member with rfl | old
      · simp
      · exact List.mem_cons_of_mem _ (boundKeys x old)
    obtain ⟨restFlatType, restFlatAbstract, restMono⟩ :=
      ihRest ((v, a) :: aenv) ((v, rhsType) :: tenv) middle next type (v :: bound) after
        (site ++ [1]) result childFuel _ (static.bind v rhsFlatType rhsFlatAbstract)
        restTyped restShadow restBoundKeys (by exact defaultConfig) restRun
    exact ⟨restFlatType, restFlatAbstract, fun origin escaped => restMono origin (rhsMono origin escaped)⟩
  | @literal args atomsFlat =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨listType, allInt⟩ := primType_literal_int_success primTyped
    subst listType
    have argsRun := static_atoms_scalar static atomsFlat atomsTyped allInt
    obtain ⟨checkerState, element, certificate, resultShape, elementFlat⟩ :=
      infer_literal_success defaultConfig argsRun accepted
    subst checkerState
    refine ⟨.listInt, ?_, fun _ escaped => escaped⟩
    rw [resultShape]
    rcases elementFlat with rfl | rfl
    · exact .listBottom _ _
    · exact .listScalar _ _
  | @push receiver item receiverFlat itemFlat =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨tR, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
    obtain ⟨tI, rest', itemTyped, restTyped', shape'⟩ := except_mapM_cons_success restTyped
    have restNil := except_mapM_nil_success restTyped'
    subst shape
    subst shape'
    subst restNil
    obtain ⟨listType, intType, resultType⟩ :=
      primType_push_success (static_atom_type static receiverFlat headTyped)
        (static_atom_type static itemFlat itemTyped) primTyped
    subst listType
    subst intType
    subst resultType
    obtain ⟨roots, element, certificate, receiverRun, elementFlat⟩ :=
      static_atom_list static receiverFlat headTyped
    have itemRun := static_atom_scalar static itemFlat itemTyped
    have abstractAtoms : [receiver, item].mapM (m := Except String) (abstractAtom aenv) =
        .ok [.list roots element certificate, .scalar] :=
      except_mapM_cons receiverRun (except_mapM_cons itemRun rfl)
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
    have demanded := primitive_push_demand_run run
    rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
      defaultConfig] at demanded
    have escapesEq := demand_success_escapes demanded
    obtain ⟨certificate', resultEq⟩ := primitive_push_result run
    refine ⟨.listInt, ?_, by rw [escapesEq]; exact fun _ escaped => escaped⟩
    rw [resultEq, flat_join_scalar elementFlat]
    exact .listScalar _ _
  | @length receiver receiverFlat =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨headType, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
    have restNil := except_mapM_nil_success restTyped
    subst shape
    subst restNil
    obtain ⟨listType, intType⟩ :=
      primType_length_success (static_atom_type static receiverFlat headTyped) primTyped
    subst listType
    subst intType
    obtain ⟨roots, element, certificate, receiverRun, _⟩ :=
      static_atom_list static receiverFlat headTyped
    have abstractAtoms : [receiver].mapM (m := Except String) (abstractAtom aenv) =
        .ok [.list roots element certificate] := except_mapM_cons receiverRun rfl
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
    rw [primitive_length_run] at run
    have equal := Except.ok.inj run
    have first : Abstract.scalar = result := congrArg Prod.fst equal
    have second : next = {before with facts := {before.facts with
        reads := union before.facts.reads ((Abstract.list roots element certificate).roots.filter external)}} :=
      (congrArg Prod.snd equal).symm
    refine ⟨.int, ?_, ?_⟩
    · rw [← first]; exact .int
    · rw [second]; exact fun _ escaped => escaped
  | @shared value valueFlat =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    have atomTyped := exprType_shared_success typed
    have flatType := static_atom_type static valueFlat atomTyped
    obtain ⟨abstract, run, shape⟩ := static_atom_abstract static valueFlat atomTyped
    have abstractAtoms : [value].mapM (m := Except String) (abstractAtom aenv) = .ok [abstract] :=
      except_mapM_cons run rfl
    obtain ⟨childFuel, _, _, primRun⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
    rw [primitive_shared_run {ctx with escaped := union ctx.escaped before.facts.escapes} defaultConfig] at primRun
    have equal := Except.ok.inj primRun
    have first : abstract.mapOrigins (fun _ cs => if cs.isEmpty then [] else union cs [.shared]) =
        result := congrArg Prod.fst equal
    have second : next = {before with facts := {before.facts with
        escapes := union before.facts.escapes abstract.cells}} := (congrArg Prod.snd equal).symm
    refine ⟨flatType, ?_, ?_⟩
    · rw [← first]
      cases shape with
      | int => rw [scalar_mapOrigins]; exact .int
      | listBottom roots certificate =>
        rw [list_mapOrigins_flat _ _ _ _ (Or.inl rfl)]; exact .listBottom _ _
      | listScalar roots certificate =>
        rw [list_mapOrigins_flat _ _ _ _ (Or.inr rfl)]; exact .listScalar _ _
    · rw [second]
      exact fun _ escaped => escaped_mono _ escaped

end Ownership.FlatFragment.Static
