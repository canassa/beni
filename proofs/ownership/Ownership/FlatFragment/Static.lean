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
open Ownership.FlatFragment.Fields Ownership.FlatFragment.Record

/-! ### Environment lookups -/

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

theorem static_atom_type {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {ty : Ty} (static : FlatStatic aenv tenv)
    (typed : atomType tenv atom = .ok ty) : FlatType ty := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact .int
  | some kp =>
    rcases kp with ⟨k, p⟩
    obtain ⟨tk, declared, at_p⟩ := atom_type_of_root typed root
    exact flatType_tyAt (static.types k tk declared) at_p

theorem static_atom_abstract {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {ty : Ty} (static : FlatStatic aenv tenv)
    (typed : atomType tenv atom = .ok ty) :
    ∃ abstract, abstractAtom aenv atom = .ok abstract ∧ FlatAbstract ty abstract := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact ⟨.scalar, rfl, .int⟩
  | some kp =>
    rcases kp with ⟨k, p⟩
    obtain ⟨tk, declared, at_p⟩ := atom_type_of_root typed root
    obtain ⟨a0, found⟩ := lookup_exists_of_same_keys aenv tenv static.keys declared
    have shape := static.shapes k tk a0 declared found
    exact ⟨a0.atPath p, abstractAtom_of_root root found shape at_p, flatAbstract_atPath shape at_p⟩

theorem static_atom_scalar {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} (static : FlatStatic aenv tenv)
    (typed : atomType tenv atom = .ok .int) : abstractAtom aenv atom = .ok .scalar := by
  obtain ⟨abstract, run, shape⟩ := static_atom_abstract static typed
  cases shape
  exact run

theorem static_atom_list {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} (static : FlatStatic aenv tenv)
    (typed : atomType tenv atom = .ok (.list .int)) :
    ∃ roots element certificate, abstractAtom aenv atom = .ok (.list roots element certificate) ∧
      (element = .bottom ∨ element = .scalar) := by
  obtain ⟨abstract, run, shape⟩ := static_atom_abstract static typed
  cases shape with
  | listBottom roots certificate => exact ⟨roots, .bottom, certificate, run, Or.inl rfl⟩
  | listScalar roots certificate => exact ⟨roots, .scalar, certificate, run, Or.inr rfl⟩

theorem static_atoms_scalar {aenv : Env Abstract} {tenv : Env Ty} {args : List Atom} {types : List Ty} (static : FlatStatic aenv tenv)
    (typed : args.mapM (atomType tenv) = .ok types) (ints : ∀ ty ∈ types, ty = .int) :
    args.mapM (m := Except String) (abstractAtom aenv) = .ok (args.map fun _ => Abstract.scalar) := by
  induction args generalizing types with
  | nil => rfl
  | cons atom rest ih =>
    obtain ⟨headType, restTypes, headTyped, restTyped, shape⟩ := except_mapM_cons_success typed
    subst shape
    have headInt : headType = .int := ints headType (by simp)
    subst headInt
    exact except_mapM_cons (static_atom_scalar static headTyped)
      (ih restTyped (fun ty member => ints ty (by simp [member])))

/-- The operands of a record constructor, statically: flat types and shapes, pointwise. -/
theorem static_atoms_abstract {aenv : Env Abstract} {tenv : Env Ty} {args : List Atom} {types : List Ty} (static : FlatStatic aenv tenv)
    (typed : args.mapM (atomType tenv) = .ok types) :
    ∃ as : List Abstract, args.mapM (m := Except String) (abstractAtom aenv) = .ok as ∧
      as.length = types.length ∧
      ∀ (i : Nat) (t : Ty) (a : Abstract), types[i]? = some t → as[i]? = some a →
        FlatType t ∧ FlatAbstract t a := by
  induction args generalizing types with
  | nil =>
    have := except_mapM_nil_success typed
    subst this
    exact ⟨[], rfl, rfl, fun i t a h => by simp at h⟩
  | cons atom rest ih =>
    obtain ⟨t, restTypes, headTyped, restTyped, rfl⟩ := except_mapM_cons_success typed
    obtain ⟨as, abstractRest, len, fields⟩ := ih restTyped
    obtain ⟨a, abstractHead, shape⟩ := static_atom_abstract static headTyped
    refine ⟨a :: as, except_mapM_cons abstractHead abstractRest, by simp [len], ?_⟩
    intro i t' a' types_i as_i
    cases i with
    | zero =>
      simp at types_i as_i
      subst types_i; subst as_i
      exact ⟨static_atom_type static headTyped, shape⟩
    | succ i => exact fields i t' a' (by simpa using types_i) (by simpa using as_i)

theorem list_mapOrigins_flat (f : Path → List Origin → List Origin) (roots : List Origin)
    (element : Abstract) (certificate : Certificate)
    (flat : element = .bottom ∨ element = .scalar) :
    (Abstract.list roots element certificate).mapOrigins f [] = .list (f [] roots) element certificate := by
  rcases flat with rfl | rfl <;> simp [Abstract.mapOrigins]

/-- The static facts of an integer primitive: an `Int` result described as a
scalar, and no new escape. -/
theorem scalar_static {aenv : Env Abstract} {tenv : Env Ty} {before next : St} {type : Ty} {after : Live} {site : List Nat} {result : Abstract} {inferenceFuel : Nat} {ctx : Context} {op : Prim} {a b : Atom} {self : Decl} {declarations : List Decl}
    (static : FlatStatic aenv tenv) (sop : ScalarOp op)
    (typed : exprType declarations self tenv (.prim op [a, b]) = .ok type)
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim op [a, b]) after site).run before =
      .ok (result, next)) :
    FlatType type ∧ FlatAbstract type result ∧
    (∀ origin, Escaped before.facts.escapes origin → Escaped next.facts.escapes origin) := by
  obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
  obtain ⟨tyA, rest, aTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
  obtain ⟨tyB, rest', bTyped, restTyped', shape'⟩ := except_mapM_cons_success restTyped
  have restNil := except_mapM_nil_success restTyped'
  subst shape
  subst shape'
  subst restNil
  obtain ⟨aInt, bInt, typeInt⟩ := primType_scalar_success sop
    (static_atom_type static aTyped) (static_atom_type static bTyped) primTyped
  subst aInt
  subst bInt
  subst typeInt
  have aRun := static_atom_scalar static aTyped
  have bRun := static_atom_scalar static bTyped
  have abstractAtoms : [a, b].mapM (m := Except String) (abstractAtom aenv) =
      .ok [.scalar, .scalar] := except_mapM_cons aRun (except_mapM_cons bRun rfl)
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
  rw [primitive_scalar_run sop] at run
  have equal := Except.ok.inj run
  have first : Abstract.scalar = result := congrArg Prod.fst equal
  have second : next = before := (congrArg Prod.snd equal).symm
  refine ⟨.int, ?_, ?_⟩
  · rw [← first]; exact .int
  · rw [second]; exact fun _ escaped => escaped

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
  | @atom a =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨atomRun, checkerState⟩ := infer_atom_success defaultConfig accepted
    subst checkerState
    have atomTyped : atomType tenv a = .ok type := typed
    obtain ⟨abstract, run, shape⟩ := static_atom_abstract static atomTyped
    rw [run] at atomRun
    cases Except.ok.inj atomRun
    exact ⟨static_atom_type static atomTyped, shape, fun _ escaped => escaped⟩
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
  | @literal args =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨listType, allInt⟩ := primType_literal_int_success primTyped
    subst listType
    have argsRun := static_atoms_scalar static atomsTyped allInt
    obtain ⟨checkerState, element, certificate, resultShape, elementFlat⟩ :=
      infer_literal_success defaultConfig argsRun accepted
    subst checkerState
    refine ⟨.listInt, ?_, fun _ escaped => escaped⟩
    rw [resultShape]
    rcases elementFlat with rfl | rfl
    · exact .listBottom _ _
    · exact .listScalar _ _
  | @push receiver item receiverFlat =>
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
      primType_push_success (static_atom_type static headTyped)
        (static_atom_type static itemTyped) primTyped
    subst listType
    subst intType
    subst resultType
    obtain ⟨roots, element, certificate, receiverRun, elementFlat⟩ :=
      static_atom_list static headTyped
    have itemRun := static_atom_scalar static itemTyped
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
  | @length receiver =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨headType, rest, headTyped, restTyped, shape⟩ := except_mapM_cons_success atomsTyped
    have restNil := except_mapM_nil_success restTyped
    subst shape
    subst restNil
    obtain ⟨listType, intType⟩ :=
      primType_length_success (static_atom_type static headTyped) primTyped
    subst listType
    subst intType
    obtain ⟨roots, element, certificate, receiverRun, _⟩ :=
      static_atom_list static headTyped
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
  | @scalar op a b sop =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    exact scalar_static static sop typed defaultConfig accepted
  | @shared value =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    have atomTyped := exprType_shared_success typed
    have flatType := static_atom_type static atomTyped
    obtain ⟨abstract, run, shape⟩ := static_atom_abstract static atomTyped
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
    · rw [← first]; exact flatAbstract_mapOrigins _ shape []
    · rw [second]
      exact fun _ escaped => escaped_mono _ escaped

  | @record args =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, rfl⟩ := exprType_record_success typed
    obtain ⟨as, abstractAtoms, lenA, fields⟩ := static_atoms_abstract static atomsTyped
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig abstractAtoms accepted
    rw [primitive_record_run _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
      Context).config = {} from defaultConfig)] at run
    have equal := Except.ok.inj run
    have first : Abstract.record as = result := congrArg Prod.fst equal
    have second : next = before := (congrArg Prod.snd equal).symm
    refine ⟨.record types ?_, ?_, by rw [second]; exact fun _ escaped => escaped⟩
    · intro t member
      obtain ⟨i, types_i⟩ := List.mem_iff_getElem?.mp member
      obtain ⟨a, as_i⟩ := index_of_same_length lenA.symm types_i
      exact (fields i t a types_i as_i).1
    · rw [← first]
      exact .record types as lenA.symm (fun i t a types_i as_i => (fields i t a types_i as_i).2)

end Ownership.FlatFragment.Static
