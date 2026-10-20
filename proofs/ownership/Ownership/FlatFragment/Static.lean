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
open Ownership.FlatFragment.InferBranch Ownership.FlatFragment.Shared Ownership.FlatFragment.InferResultCase
open Ownership.FlatFragment.InferChainCase Ownership.FlatFragment.Chain Ownership.FlatFragment.ListPrimitives
open Ownership.FlatFragment.Result Ownership.FlatFragment.NamingFacts Ownership.FlatFragment.Description

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)
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

/-- The checker's reading of a field: the record it read and the field it took. -/
theorem abstractAtom_field_success {aenv : Env Abstract} {a : Atom} {i : Nat} {abstract : Abstract}
    (run : abstractAtom aenv (.field a i) = .ok abstract) :
    ∃ xs, abstractAtom aenv a = .ok (.record xs) ∧ xs[i]? = some abstract := by
  rw [abstractAtom] at run
  cases h : abstractAtom aenv a with
  | error m => rw [h] at run; simp [Bind.bind, Except.bind] at run
  | ok v =>
    rw [h] at run
    cases v <;> simp [Bind.bind, Except.bind] at run
    rename_i xs
    cases h' : xs[i]? with
    | none => simp [h', Option.toExcept] at run
    | some x =>
      simp [h', Option.toExcept, pure, Except.pure] at run
      subst run
      exact ⟨xs, rfl, h'⟩

/-- The shape of an atom the checker read: the flat shape of its type. A
field of a dead record (its abstract bottom) fails the read, so a read that
succeeded went through records. -/
theorem static_atom_shape {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {ty : Ty} {abstract : Abstract}
    (static : FlatStatic aenv tenv) (typed : atomType tenv atom = .ok ty)
    (run : abstractAtom aenv atom = .ok abstract) : FlatAbstract ty abstract := by
  induction atom generalizing ty abstract with
  | int n =>
    have tyInt : ty = .int := (Except.ok.inj typed).symm
    have scalar : abstract = .scalar := (Except.ok.inj run).symm
    subst tyInt
    subst scalar
    exact .int
  | var v =>
    have declared : tenv.lookup v = some ty := lookup_option_of_success typed
    have found : aenv.lookup v = some abstract := lookup_option_of_success run
    exact static.shapes v ty abstract declared found
  | field a i ih =>
    obtain ⟨fs, innerTyped, fs_i⟩ := atomType_field typed
    obtain ⟨xs, innerRun, xs_i⟩ := abstractAtom_field_success run
    cases ih innerTyped innerRun with
    | record _ _ len fields => exact fields i ty abstract fs_i xs_i

theorem static_atom_scalar {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {abstract : Abstract}
    (static : FlatStatic aenv tenv) (typed : atomType tenv atom = .ok .int)
    (run : abstractAtom aenv atom = .ok abstract) : abstract = .bottom ∨ abstract = .scalar := by
  cases static_atom_shape static typed run with
  | bottom _ => exact Or.inl rfl
  | int => exact Or.inr rfl

theorem static_atom_list {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {abstract : Abstract}
    (static : FlatStatic aenv tenv) (typed : atomType tenv atom = .ok (.list .int))
    (run : abstractAtom aenv atom = .ok abstract) :
    abstract = .bottom ∨ ∃ roots element certificate, abstract = .list roots element certificate ∧
      (element = .bottom ∨ element = .scalar) := by
  cases static_atom_shape static typed run with
  | bottom _ => exact Or.inl rfl
  | listBottom roots certificate => exact Or.inr ⟨roots, .bottom, certificate, rfl, Or.inl rfl⟩
  | listScalar roots certificate => exact Or.inr ⟨roots, .scalar, certificate, rfl, Or.inr rfl⟩

theorem static_atom_chain {aenv : Env Abstract} {tenv : Env Ty} {atom : Atom} {abstract : Abstract}
    (static : FlatStatic aenv tenv) (typed : atomType tenv atom = .ok (.chain .int))
    (run : abstractAtom aenv atom = .ok abstract) :
    abstract = .bottom ∨ ∃ roots element certificate, abstract = .list roots element certificate ∧
      (element = .bottom ∨ element = .scalar) := by
  cases static_atom_shape static typed run with
  | bottom _ => exact Or.inl rfl
  | chainBottom roots certificate => exact Or.inr ⟨roots, .bottom, certificate, rfl, Or.inl rfl⟩
  | chainScalar roots certificate => exact Or.inr ⟨roots, .scalar, certificate, rfl, Or.inr rfl⟩

theorem static_atoms_scalar {aenv : Env Abstract} {tenv : Env Ty} {args : List Atom} {types : List Ty} {as : List Abstract}
    (static : FlatStatic aenv tenv)
    (typed : args.mapM (atomType tenv) = .ok types) (ints : ∀ ty ∈ types, ty = .int)
    (run : args.mapM (m := Except String) (abstractAtom aenv) = .ok as) :
    ∀ a ∈ as, a = .bottom ∨ a = .scalar := by
  obtain ⟨lenT, fieldsT⟩ := mapM_ok_fields typed
  obtain ⟨lenA, fieldsA⟩ := mapM_ok_fields run
  intro a member
  obtain ⟨i, as_i⟩ := List.mem_iff_getElem?.mp member
  obtain ⟨atom, args_i⟩ := index_of_same_length lenA.symm as_i
  obtain ⟨ty, types_i⟩ := index_of_same_length lenT args_i
  have tyInt := ints ty (List.mem_of_getElem? types_i)
  subst tyInt
  exact static_atom_scalar static (fieldsT i atom _ args_i types_i) (fieldsA i atom a args_i as_i)

/-- The operands of a record constructor, statically: flat types and shapes, pointwise. -/
theorem static_atoms_abstract {aenv : Env Abstract} {tenv : Env Ty} {args : List Atom} {types : List Ty} {as : List Abstract}
    (static : FlatStatic aenv tenv)
    (typed : args.mapM (atomType tenv) = .ok types)
    (run : args.mapM (m := Except String) (abstractAtom aenv) = .ok as) :
    as.length = types.length ∧
      ∀ (i : Nat) (t : Ty) (a : Abstract), types[i]? = some t → as[i]? = some a →
        FlatType t ∧ FlatAbstract t a := by
  obtain ⟨lenT, fieldsT⟩ := mapM_ok_fields typed
  obtain ⟨lenA, fieldsA⟩ := mapM_ok_fields run
  refine ⟨lenA.symm.trans lenT, ?_⟩
  intro i t a types_i as_i
  obtain ⟨atom, args_i⟩ := index_of_same_length lenA.symm as_i
  exact ⟨static_atom_type static (fieldsT i atom t args_i types_i),
    static_atom_shape static (fieldsT i atom t args_i types_i) (fieldsA i atom a args_i as_i)⟩

theorem list_mapOrigins_flat (f : Path → List Origin → List Origin) (roots : List Origin)
    (element : Abstract) (certificate : Certificate)
    (flat : element = .bottom ∨ element = .scalar) :
    (Abstract.list roots element certificate).mapOrigins f [] = .list (f [] roots) element certificate := by
  rcases flat with rfl | rfl <;> simp [Abstract.mapOrigins]

/-! ### The type of a typed fragment expression -/

theorem atom_type_flat {tenv : Env Ty} {atom : Atom} {ty : Ty}
    (types : ∀ x ty, tenv.lookup x = some ty → FlatType ty)
    (typed : atomType tenv atom = .ok ty) : FlatType ty := by
  cases root : atomRoot atom with
  | none =>
    obtain ⟨n, rfl, rfl⟩ := atom_int_of_root_none typed root
    exact .int
  | some kp =>
    rcases kp with ⟨k, p⟩
    obtain ⟨tk, declared, at_p⟩ := atom_type_of_root typed root
    exact flatType_tyAt (types k tk declared) at_p

theorem types_cons {tenv : Env Ty} {v : Var} {ty : Ty}
    (types : ∀ x ty, tenv.lookup x = some ty → FlatType ty) (flat : FlatType ty) :
    ∀ x ty', ((v, ty) :: tenv).lookup x = some ty' → FlatType ty' := by
  intro x ty' declared
  by_cases same : x = v
  · subst same
    rw [lookup_cons_same] at declared
    cases Option.some.inj declared
    exact flat
  · rw [lookup_cons_other _ _ _ same] at declared
    exact types x ty' declared

/-- The type of a well-typed fragment expression is flat, from typing alone:
a case whose checker run skipped both arms (dead code) still has a flat type. -/
theorem flat_type_of_typed {declarations : List Decl} {self : Decl} {e : Expr} (flat : FlatANF0 e) :
    ∀ (tenv : Env Ty) (type : Ty), (∀ x ty, tenv.lookup x = some ty → FlatType ty) →
      exprType declarations self tenv e = .ok type → FlatType type := by
  induction flat with
  | @atom a =>
    intro tenv type types typed
    exact atom_type_flat types typed
  | @letE rhs rest v _ _ ihRhs ihRest =>
    intro tenv type types typed
    obtain ⟨rhsType, rhsTyped, restTyped⟩ := exprType_let_success typed
    exact ihRest _ type (types_cons types (ihRhs tenv rhsType types rhsTyped)) restTyped
  | @branch yes no c _ _ ihYes _ =>
    intro tenv type types typed
    obtain ⟨_, yesTyped, _⟩ := exprType_branch_success typed
    exact ihYes tenv type types yesTyped
  | @literal args =>
    intro tenv type types typed
    obtain ⟨_, _, primTyped⟩ := exprType_prim_success typed
    obtain ⟨rfl, _⟩ := primType_literal_int_success primTyped
    exact .listInt
  | @push receiver item =>
    intro tenv type types typed
    obtain ⟨_, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨tR, _, headTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
    obtain ⟨tI, _, itemTyped, restTyped', rfl⟩ := except_mapM_cons_success restTyped
    have restNil := except_mapM_nil_success restTyped'
    subst restNil
    obtain ⟨_, _, rfl⟩ := primType_push_success (atom_type_flat types headTyped)
      (atom_type_flat types itemTyped) primTyped
    exact .listInt
  | @length receiver =>
    intro tenv type types typed
    obtain ⟨_, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨headType, _, headTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
    have restNil := except_mapM_nil_success restTyped
    subst restNil
    obtain ⟨_, rfl⟩ := primType_length_success (atom_type_flat types headTyped) primTyped
    exact .int
  | @scalar op a b sop =>
    intro tenv type types typed
    obtain ⟨_, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨tyA, _, aTyped, restTyped, rfl⟩ := except_mapM_cons_success atomsTyped
    obtain ⟨tyB, _, bTyped, restTyped', rfl⟩ := except_mapM_cons_success restTyped
    have restNil := except_mapM_nil_success restTyped'
    subst restNil
    obtain ⟨_, _, rfl⟩ := primType_scalar_success sop (atom_type_flat types aTyped)
      (atom_type_flat types bTyped) primTyped
    exact .int
  | @shared value =>
    intro tenv type types typed
    exact atom_type_flat types (exprType_shared_success typed)
  | @record args =>
    intro tenv type types typed
    obtain ⟨ts, atomsTyped, rfl⟩ := exprType_record_success typed
    obtain ⟨len, fields⟩ := mapM_ok_fields atomsTyped
    refine .record ts ?_
    intro t member
    obtain ⟨i, ts_i⟩ := List.mem_iff_getElem?.mp member
    obtain ⟨atom, args_i⟩ := index_of_same_length len.symm ts_i
    exact atom_type_flat types (fields i atom t args_i ts_i)
  | @ok error x flatError =>
    intro tenv type types typed
    obtain ⟨t, atomTyped, rfl⟩ := exprType_ok_success typed
    exact .result error t flatError (atom_type_flat types atomTyped)
  | @err success x flatSuccess =>
    intro tenv type types typed
    obtain ⟨t, atomTyped, rfl⟩ := exprType_err_success typed
    exact .result t success (atom_type_flat types atomTyped) flatSuccess
  | @resultCase onError onSuccess input err ok _ _ ihError _ =>
    intro tenv type types typed
    obtain ⟨e, a, inputTyped, errorTyped, _⟩ := exprType_resultCase_success typed
    cases atom_type_flat types inputTyped with
    | result _ _ flatE _ => exact ihError _ type (types_cons types flatE) errorTyped
  | @endChain =>
    intro tenv type types typed
    rw [exprType_endChain_success typed]
    exact .chainInt
  | @link head tail =>
    intro tenv type types typed
    obtain ⟨_, _, rfl⟩ := exprType_link_success (fun _ h => atom_type_flat types h) typed
    exact .chainInt
  | @chainCase onEnd onLink input head tail _ _ ihEnd _ =>
    intro tenv type types typed
    obtain ⟨t, _, endTyped, _⟩ := exprType_chainCase_success typed
    exact ihEnd tenv type types endTyped
  | @atRead receiver index fallback =>
    intro tenv type types typed
    obtain ⟨_, _, _, rfl⟩ := exprType_at_success (fun _ _ h => atom_type_flat types h) typed
    exact .int
  | @set receiver index item =>
    intro tenv type types typed
    obtain ⟨_, _, _, rfl⟩ := exprType_set_success (fun _ _ h => atom_type_flat types h) typed
    exact .listInt
  | @copy receiver =>
    intro tenv type types typed
    obtain ⟨_, rfl⟩ := exprType_copy_success (fun _ _ h => atom_type_flat types h) typed
    exact .listInt
  | @prepend item receiver =>
    intro tenv type types typed
    obtain ⟨_, _, rfl⟩ := exprType_prepend_success (fun _ _ h => atom_type_flat types h) typed
    exact .listInt

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
  obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
  obtain ⟨x, rest1, _, restRun, shape1⟩ := except_mapM_cons_success argsRun
  obtain ⟨y, rest2, _, restRun', shape2⟩ := except_mapM_cons_success restRun
  have restNil' := except_mapM_nil_success restRun'
  subst shape1
  subst shape2
  subst restNil'
  obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
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
    exact ⟨static_atom_type static atomTyped, static_atom_shape static atomTyped atomRun,
      fun _ escaped => escaped⟩
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
  | @branch yes no c _ _ ihYes ihNo =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed shadow boundKeys defaultConfig accepted
    obtain ⟨_, yesTyped, b', noTyped, equalTypes⟩ := exprType_branch_success typed
    obtain ⟨yesShadow, noShadow⟩ := shadowFree_branch_success shadow
    obtain ⟨childFuel, a, middle, b, last, _, _, _, yesRun, noRun, resultEq, nextEq⟩ :=
      infer_branch_success defaultConfig accepted
    obtain ⟨flatType, yesShape, yesMono⟩ :=
      ihYes aenv tenv before middle type bound after (site ++ [0]) a childFuel _
        static yesTyped yesShadow boundKeys (by exact defaultConfig) yesRun
    have sameType : type = b' := ty_equal_flat flatType equalTypes
    subst sameType
    obtain ⟨_, noShape, _⟩ :=
      ihNo aenv tenv {middle with facts := before.facts} last type bound after (site ++ [1]) b
        childFuel _ static noTyped noShadow boundKeys (by exact defaultConfig) noRun
    refine ⟨flatType, by rw [resultEq]; exact flatAbstract_join yesShape noShape, ?_⟩
    intro origin escaped
    rw [nextEq, join_escapes]
    exact escaped_mono _ (yesMono origin escaped)
  | @literal args =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨types, atomsTyped, primTyped⟩ := exprType_prim_success typed
    obtain ⟨listType, allInt⟩ := primType_literal_int_success primTyped
    subst listType
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    have flatAs := static_atoms_scalar static atomsTyped allInt argsRun
    obtain ⟨checkerState, element, certificate, resultShape, elementFlat⟩ :=
      infer_literal_success defaultConfig argsRun flatAs accepted
    subst checkerState
    refine ⟨.listInt, ?_, fun _ escaped => escaped⟩
    rw [resultShape]
    rcases elementFlat with rfl | rfl
    · exact .listBottom _ _
    · exact .listScalar _ _
  | @push receiver item =>
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
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨r, rest1, receiverRun, restRun, shape1⟩ := except_mapM_cons_success argsRun
    obtain ⟨it, rest2, itemRun, restRun', shape2⟩ := except_mapM_cons_success restRun
    have restNil' := except_mapM_nil_success restRun'
    subst shape1
    subst shape2
    subst restNil'
    have itemFlat := static_atom_scalar static itemTyped itemRun
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rcases static_atom_list static headTyped receiverRun with rfl |
      ⟨roots, element, certificate, rfl, elementFlat⟩
    · -- A push onto a dead receiver: the checker returns bottom.
      rw [primitive_push_bottom_run] at run
      have equal := Except.ok.inj run
      have first : Abstract.bottom = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      refine ⟨.listInt, ?_, ?_⟩
      · rw [← first]; exact .bottom _
      · rw [second]; exact fun _ escaped => escaped
    · have demanded := primitive_push_demand_run run
      rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
        defaultConfig] at demanded
      have escapesEq := demand_success_escapes demanded
      obtain ⟨certificate', resultEq⟩ := primitive_push_result_flat itemFlat run
      refine ⟨.listInt, ?_, by rw [escapesEq]; exact fun _ escaped => escaped⟩
      rw [resultEq]
      rcases flat_join_flat elementFlat itemFlat with joined | joined
      · rw [joined]; exact .listBottom _ _
      · rw [joined]; exact .listScalar _ _
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
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨r, rest1, _, restRun, shape1⟩ := except_mapM_cons_success argsRun
    have restNil' := except_mapM_nil_success restRun
    subst shape1
    subst restNil'
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rw [primitive_length_run] at run
    have equal := Except.ok.inj run
    have first : Abstract.scalar = result := congrArg Prod.fst equal
    have second : next = {before with facts := {before.facts with
        reads := union before.facts.reads (r.roots.filter external)}} :=
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
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨abstract, rest1, run, restRun, shape1⟩ := except_mapM_cons_success argsRun
    have restNil' := except_mapM_nil_success restRun
    subst shape1
    subst restNil'
    have shape := static_atom_shape static atomTyped run
    obtain ⟨childFuel, _, _, primRun⟩ := infer_primitive_success defaultConfig argsRun accepted
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
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨lenA, fields⟩ := static_atoms_abstract static atomsTyped argsRun
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
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
  | @ok error x flatError =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨t, atomTyped, rfl⟩ := exprType_ok_success typed
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨a, rest1, run, restRun, shape1⟩ := except_mapM_cons_success argsRun
    have restNil' := except_mapM_nil_success restRun
    subst shape1
    subst restNil'
    have shape := static_atom_shape static atomTyped run
    obtain ⟨childFuel, _, _, primRun⟩ := infer_primitive_success defaultConfig argsRun accepted
    rw [primitive_ok_run] at primRun
    have equal := Except.ok.inj primRun
    have first : Abstract.record [.scalar, .bottom, a] = result := congrArg Prod.fst equal
    have second : next = before := (congrArg Prod.snd equal).symm
    refine ⟨.result error t flatError (static_atom_type static atomTyped), ?_,
      by rw [second]; exact fun _ escaped => escaped⟩
    rw [← first]
    exact .result error t .bottom a (.bottom _) shape
  | @err success x flatSuccess =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨t, atomTyped, rfl⟩ := exprType_err_success typed
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨a, rest1, run, restRun, shape1⟩ := except_mapM_cons_success argsRun
    have restNil' := except_mapM_nil_success restRun
    subst shape1
    subst restNil'
    have shape := static_atom_shape static atomTyped run
    obtain ⟨childFuel, _, _, primRun⟩ := infer_primitive_success defaultConfig argsRun accepted
    rw [primitive_err_run _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
      Context).config = {} from defaultConfig)] at primRun
    have equal := Except.ok.inj primRun
    have first : Abstract.record [.scalar, a, .bottom] = result := congrArg Prod.fst equal
    have second : next = before := (congrArg Prod.snd equal).symm
    refine ⟨.result t success (static_atom_type static atomTyped) flatSuccess, ?_,
      by rw [second]; exact fun _ escaped => escaped⟩
    rw [← first]
    exact .result t success a .bottom shape (.bottom _)
  | @resultCase onError onSuccess input err ok flatError flatSuccess ihError ihSuccess =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed shadow boundKeys defaultConfig accepted
    obtain ⟨e, a, inputTyped, errorTyped, b', successTyped, equalTypes⟩ :=
      exprType_resultCase_success typed
    obtain ⟨errFresh, okFresh, errorShadow, successShadow⟩ := shadowFree_resultCase_success shadow
    obtain ⟨abstract, run⟩ := infer_resultCase_atom_success defaultConfig accepted
    have shape := static_atom_shape static inputTyped run
    have inputFlat := static_atom_type static inputTyped
    cases inputFlat with
    | result _ _ flatE flatA =>
      have flatType : FlatType type :=
        flat_type_of_typed flatError ((err, e) :: tenv) type (types_cons static.types flatE) errorTyped
      cases shape with
      | bottom _ =>
        -- A case on a dead input: the checker returns bottom.
        obtain ⟨resultBottom, nextSame⟩ := infer_resultCase_bottom_success defaultConfig run accepted
        subst resultBottom
        subst nextSame
        exact ⟨flatType, .bottom _, fun _ escaped => escaped⟩
      | result _ _ ae aa hE hS =>
        obtain ⟨childFuel, left, middle, right, last, _, _, leftRun, rightRun, resultEq, nextEq⟩ :=
          infer_resultCase_success defaultConfig run accepted
        have errorBoundKeys : ∀ x ∈ ((err, ae) :: aenv).map Prod.fst, x ∈ err :: bound := by
          intro x member
          simp only [List.map_cons, List.mem_cons] at member
          rcases member with rfl | old
          · simp
          · exact List.mem_cons_of_mem _ (boundKeys x old)
        have successBoundKeys : ∀ x ∈ ((ok, aa) :: aenv).map Prod.fst, x ∈ ok :: bound := by
          intro x member
          simp only [List.map_cons, List.mem_cons] at member
          rcases member with rfl | old
          · simp
          · exact List.mem_cons_of_mem _ (boundKeys x old)
        have escapesEq : next.facts.escapes = union middle.facts.escapes last.facts.escapes := by
          rw [nextEq]; rfl
        -- An inferred error arm.
        have errorArm : (ae == .bottom) = false →
            (inferExpr childFuel {ctx with escaped := union ctx.escaped before.facts.escapes}
              ((err, ae) :: aenv) onError after (site ++ [0])).run before = .ok (left, middle) →
            FlatType type ∧ FlatAbstract type left ∧
              (∀ origin, Escaped before.facts.escapes origin → Escaped middle.facts.escapes origin) := by
          intro _ armRun
          exact ihError ((err, ae) :: aenv) ((err, e) :: tenv) before middle type (err :: bound) after
            (site ++ [0]) left childFuel _ (static.bind err flatE hE) errorTyped errorShadow
            errorBoundKeys (by exact defaultConfig) armRun
        -- An inferred success arm.
        have successArm : (aa == .bottom) = false →
            (inferExpr childFuel {ctx with escaped := union ctx.escaped before.facts.escapes}
              ((ok, aa) :: aenv) onSuccess after (site ++ [1])).run {middle with facts := before.facts} =
              .ok (right, last) →
            FlatType b' ∧ FlatAbstract b' right ∧
              (∀ origin, Escaped before.facts.escapes origin → Escaped last.facts.escapes origin) := by
          intro _ armRun
          exact ihSuccess ((ok, aa) :: aenv) ((ok, a) :: tenv) {middle with facts := before.facts} last b'
            (ok :: bound) after (site ++ [1]) right childFuel _ (static.bind ok flatA hS)
            successTyped successShadow successBoundKeys (by exact defaultConfig) armRun
        rcases leftRun with ⟨bottomE, rfl, rfl⟩ | ⟨bottomE, leftRun⟩
        · rcases rightRun with ⟨bottomS, rfl, rfl⟩ | ⟨bottomS, rightRun⟩
          · -- Both arms are skipped: dead code, the result is bottom.
            refine ⟨flatType, ?_, ?_⟩
            · rw [resultEq, join_bottom_bottom]; exact .bottom _
            · intro origin escaped
              rw [escapesEq]
              exact escaped_mono _ escaped
          · -- The error arm is skipped; the success arm is live.
            obtain ⟨flatB, rightShape, rightMono⟩ := successArm bottomS rightRun
            have sameType : type = b' := ty_equal_flat_right flatB equalTypes
            subst sameType
            refine ⟨flatB, ?_, ?_⟩
            · rw [resultEq, join_bottom_left]; exact rightShape
            · intro origin escaped
              rw [escapesEq]
              exact escaped_subset (fun x member => mem_union _ _ x (Or.inr member)) (rightMono origin escaped)
        · obtain ⟨flatType', leftShape, leftMono⟩ := errorArm bottomE leftRun
          rcases rightRun with ⟨bottomS, rfl, rfl⟩ | ⟨bottomS, rightRun⟩
          · refine ⟨flatType', ?_, ?_⟩
            · rw [resultEq, join_bottom_right]; exact leftShape
            · intro origin escaped
              rw [escapesEq]
              exact escaped_mono _ (leftMono origin escaped)
          · obtain ⟨_, rightShape, _⟩ := successArm bottomS rightRun
            have sameType : type = b' := ty_equal_flat flatType' equalTypes
            subst sameType
            refine ⟨flatType', ?_, ?_⟩
            · rw [resultEq]; exact flatAbstract_join leftShape rightShape
            · intro origin escaped
              rw [escapesEq]
              exact escaped_mono _ (leftMono origin escaped)
  | @endChain =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    have chainType := exprType_endChain_success typed
    subst chainType
    obtain ⟨checkerState, resultShape⟩ := infer_endChain_success defaultConfig accepted
    subst checkerState
    subst resultShape
    exact ⟨.chainInt, .chainBottom _ _, fun _ escaped => escaped⟩
  | @link head tail =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨headTyped, tailTyped, chainType⟩ :=
      exprType_link_success (fun _ h => static_atom_type static h) typed
    subst chainType
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨h, rest1, headRun, restRun, shape1⟩ := except_mapM_cons_success argsRun
    obtain ⟨t, rest2, tailRun, restRun', shape2⟩ := except_mapM_cons_success restRun
    have restNil' := except_mapM_nil_success restRun'
    subst shape1
    subst shape2
    subst restNil'
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rcases static_atom_chain static tailTyped tailRun with rfl |
      ⟨roots, element, certificate, rfl, elementFlat⟩
    · -- A link onto a dead chain: the checker returns bottom.
      have bottomRun : (primitive {ctx with escaped := union ctx.escaped before.facts.escapes} site .link
          [h, .bottom] (union (liveCellsWith ctx.config aenv after) ctx.pinned)).run before =
          .ok (.bottom, before) := by
        unfold primitive
        simp [BEq.beq, Abstract.equal]
        rfl
      rw [bottomRun] at run
      have equal := Except.ok.inj run
      have first : Abstract.bottom = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      refine ⟨.chainInt, ?_, ?_⟩
      · rw [← first]; exact .bottom _
      · rw [second]; exact fun _ escaped => escaped
    · rw [primitive_link_run _ (show ({ctx with escaped := union ctx.escaped before.facts.escapes} :
        Context).config = {} from defaultConfig)] at run
      have equal := Except.ok.inj run
      have first : _ = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      have headFlat := static_atom_scalar static headTyped headRun
      refine ⟨.chainInt, ?_, by rw [second]; exact fun _ escaped => escaped⟩
      rw [← first]
      rcases flat_join_flat headFlat elementFlat with joined | joined
      · rw [joined]; exact .chainBottom _ _
      · rw [joined]; exact .chainScalar _ _
  | @chainCase onEnd onLink input head tail flatEnd flatLink ihEnd ihLink =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed shadow boundKeys defaultConfig accepted
    obtain ⟨t, inputTyped, endTyped, b', linkTyped, equalTypes⟩ := exprType_chainCase_success typed
    obtain ⟨headFresh, tailFresh, different, endShadow, linkShadow⟩ := shadowFree_chainCase_success shadow
    obtain ⟨abstract, run⟩ := infer_chainCase_atom_success defaultConfig accepted
    have shape := static_atom_shape static inputTyped run
    have inputFlat := static_atom_type static inputTyped
    cases inputFlat with
    | chainInt =>
      cases shape with
      | bottom _ =>
        -- A case on a dead input: the checker returns bottom.
        obtain ⟨resultBottom, nextSame⟩ := infer_chainCase_bottom_success defaultConfig run accepted
        subst resultBottom
        subst nextSame
        exact ⟨flat_type_of_typed flatEnd tenv type static.types endTyped, .bottom _,
          fun _ escaped => escaped⟩
      | chainBottom roots certificate =>
        obtain ⟨childFuel, left, middle, right, last, _, _, leftRun, rightRun, resultEq, nextEq⟩ :=
          infer_chainCase_success defaultConfig run accepted
        obtain ⟨flatType, leftShape, leftMono⟩ :=
          ihEnd aenv tenv before middle type bound after (site ++ [0]) left childFuel _ static endTyped
            endShadow boundKeys (by exact defaultConfig) leftRun
        have sameType : type = b' := ty_equal_flat flatType equalTypes
        subst sameType
        have linkBoundKeys : ∀ x ∈ ((head, Abstract.bottom) :: (tail, Abstract.list roots .bottom certificate) :: aenv).map Prod.fst,
            x ∈ head :: tail :: bound := by
          intro x member
          simp only [List.map_cons, List.mem_cons] at member
          rcases member with rfl | rfl | old
          · simp
          · simp
          · exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ (boundKeys x old))
        obtain ⟨_, rightShape, _⟩ :=
          ihLink ((head, .bottom) :: (tail, .list roots .bottom certificate) :: aenv)
            ((head, .int) :: (tail, .chain .int) :: tenv) {middle with facts := before.facts} last type
            (head :: tail :: bound) after (site ++ [1]) right childFuel _
            ((static.bind tail .chainInt (.chainBottom _ _)).bind head .int (.bottom _)) linkTyped
            linkShadow linkBoundKeys (by exact defaultConfig) rightRun
        refine ⟨flatType, by rw [resultEq]; exact flatAbstract_join leftShape rightShape, ?_⟩
        intro origin escaped
        rw [nextEq, join_escapes]
        exact escaped_mono _ (leftMono origin escaped)
      | chainScalar roots certificate =>
        obtain ⟨childFuel, left, middle, right, last, _, _, leftRun, rightRun, resultEq, nextEq⟩ :=
          infer_chainCase_success defaultConfig run accepted
        obtain ⟨flatType, leftShape, leftMono⟩ :=
          ihEnd aenv tenv before middle type bound after (site ++ [0]) left childFuel _ static endTyped
            endShadow boundKeys (by exact defaultConfig) leftRun
        have sameType : type = b' := ty_equal_flat flatType equalTypes
        subst sameType
        have linkBoundKeys : ∀ x ∈ ((head, Abstract.scalar) :: (tail, Abstract.list roots .scalar certificate) :: aenv).map Prod.fst,
            x ∈ head :: tail :: bound := by
          intro x member
          simp only [List.map_cons, List.mem_cons] at member
          rcases member with rfl | rfl | old
          · simp
          · simp
          · exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ (boundKeys x old))
        obtain ⟨_, rightShape, _⟩ :=
          ihLink ((head, .scalar) :: (tail, .list roots .scalar certificate) :: aenv)
            ((head, .int) :: (tail, .chain .int) :: tenv) {middle with facts := before.facts} last type
            (head :: tail :: bound) after (site ++ [1]) right childFuel _
            ((static.bind tail .chainInt (.chainScalar _ _)).bind head .int .int) linkTyped
            linkShadow linkBoundKeys (by exact defaultConfig) rightRun
        refine ⟨flatType, by rw [resultEq]; exact flatAbstract_join leftShape rightShape, ?_⟩
        intro origin escaped
        rw [nextEq, join_escapes]
        exact escaped_mono _ (leftMono origin escaped)
  | @atRead receiver index fallback =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨receiverTyped, indexTyped, fallbackTyped, intType⟩ :=
      exprType_at_success (fun _ _ h => static_atom_type static h) typed
    subst intType
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨r, rest1, receiverRun, restRun, shape1⟩ := except_mapM_cons_success argsRun
    obtain ⟨ix, rest2, indexRun, restRun', shape2⟩ := except_mapM_cons_success restRun
    obtain ⟨fb, rest3, fallbackRun, restRun'', shape3⟩ := except_mapM_cons_success restRun'
    have restNil' := except_mapM_nil_success restRun''
    subst shape1
    subst shape2
    subst shape3
    subst restNil'
    have fallbackFlat := static_atom_scalar static fallbackTyped fallbackRun
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rcases static_atom_list static receiverTyped receiverRun with rfl |
      ⟨roots, element, certificate, rfl, elementFlat⟩
    · rw [primitive_at_bottom_run] at run
      have equal := Except.ok.inj run
      have first : Abstract.bottom = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      refine ⟨.int, ?_, ?_⟩
      · rw [← first]; exact .bottom _
      · rw [second]; exact fun _ escaped => escaped
    · rw [primitive_at_run] at run
      have equal := Except.ok.inj run
      have first : element.join fb = result := congrArg Prod.fst equal
      have second : next = {before with facts := {before.facts with
          reads := union before.facts.reads ((union roots element.cells).filter external)}} :=
        (congrArg Prod.snd equal).symm
      refine ⟨.int, ?_, ?_⟩
      · rw [← first]
        rcases flat_join_flat elementFlat fallbackFlat with joined | joined
        · rw [joined]; exact .bottom _
        · rw [joined]; exact .int
      · rw [second]; exact fun _ escaped => escaped
  | @set receiver index item =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨receiverTyped, indexTyped, itemTyped, listType⟩ :=
      exprType_set_success (fun _ _ h => static_atom_type static h) typed
    subst listType
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨r, rest1, receiverRun, restRun, shape1⟩ := except_mapM_cons_success argsRun
    obtain ⟨ix, rest2, indexRun, restRun', shape2⟩ := except_mapM_cons_success restRun
    obtain ⟨it, rest3, itemRun, restRun'', shape3⟩ := except_mapM_cons_success restRun'
    have restNil' := except_mapM_nil_success restRun''
    subst shape1
    subst shape2
    subst shape3
    subst restNil'
    have itemFlat := static_atom_scalar static itemTyped itemRun
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rcases static_atom_list static receiverTyped receiverRun with rfl |
      ⟨roots, element, certificate, rfl, elementFlat⟩
    · rw [primitive_set_bottom_run] at run
      have equal := Except.ok.inj run
      have first : Abstract.bottom = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      refine ⟨.listInt, ?_, ?_⟩
      · rw [← first]; exact .bottom _
      · rw [second]; exact fun _ escaped => escaped
    · have demanded := primitive_set_demand_run run
      rw [show ({ctx with escaped := union ctx.escaped before.facts.escapes} : Context).config = {} from
        defaultConfig] at demanded
      have escapesEq := demand_success_escapes demanded
      obtain ⟨certificate', resultEq⟩ := primitive_set_result itemFlat run
      refine ⟨.listInt, ?_, by rw [escapesEq]; exact fun _ escaped => escaped⟩
      rw [resultEq]
      rcases flat_join_flat elementFlat itemFlat with joined | joined
      · rw [joined]; exact .listBottom _ _
      · rw [joined]; exact .listScalar _ _
  | @copy receiver =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨receiverTyped, listType⟩ :=
      exprType_copy_success (fun _ _ h => static_atom_type static h) typed
    subst listType
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨r, rest1, receiverRun, restRun, shape1⟩ := except_mapM_cons_success argsRun
    have restNil' := except_mapM_nil_success restRun
    subst shape1
    subst restNil'
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rcases static_atom_list static receiverTyped receiverRun with rfl |
      ⟨roots, element, certificate, rfl, elementFlat⟩
    · rw [primitive_copy_bottom_run] at run
      have equal := Except.ok.inj run
      have first : Abstract.bottom = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      refine ⟨.listInt, ?_, ?_⟩
      · rw [← first]; exact .bottom _
      · rw [second]; exact fun _ escaped => escaped
    · obtain ⟨certificate', copyRun⟩ := primitive_copy_run
        {ctx with escaped := union ctx.escaped before.facts.escapes} site roots element certificate
        (union (liveCellsWith ctx.config aenv after) ctx.pinned) before
      rw [copyRun] at run
      have equal := Except.ok.inj run
      have first : Abstract.list [.site site 0] element certificate' = result := congrArg Prod.fst equal
      have second : next = {before with facts := {before.facts with
          reads := union before.facts.reads (roots.filter external)}} := (congrArg Prod.snd equal).symm
      refine ⟨.listInt, ?_, by rw [second]; exact fun _ escaped => escaped⟩
      rw [← first]
      rcases elementFlat with rfl | rfl
      · exact .listBottom _ _
      · exact .listScalar _ _
  | @prepend item receiver =>
    intro aenv tenv before next type bound after site result inferenceFuel ctx
      static typed _ _ defaultConfig accepted
    obtain ⟨itemTyped, receiverTyped, listType⟩ :=
      exprType_prepend_success (fun _ _ h => static_atom_type static h) typed
    subst listType
    obtain ⟨as, argsRun⟩ := infer_primitive_args_success defaultConfig accepted
    obtain ⟨it, rest1, itemRun, restRun, shape1⟩ := except_mapM_cons_success argsRun
    obtain ⟨r, rest2, receiverRun, restRun', shape2⟩ := except_mapM_cons_success restRun
    have restNil' := except_mapM_nil_success restRun'
    subst shape1
    subst shape2
    subst restNil'
    have itemFlat := static_atom_scalar static itemTyped itemRun
    obtain ⟨childFuel, _, _, run⟩ := infer_primitive_success defaultConfig argsRun accepted
    rcases static_atom_list static receiverTyped receiverRun with rfl |
      ⟨roots, element, certificate, rfl, elementFlat⟩
    · rw [primitive_prepend_bottom_run] at run
      have equal := Except.ok.inj run
      have first : Abstract.bottom = result := congrArg Prod.fst equal
      have second : next = before := (congrArg Prod.snd equal).symm
      refine ⟨.listInt, ?_, ?_⟩
      · rw [← first]; exact .bottom _
      · rw [second]; exact fun _ escaped => escaped
    · obtain ⟨certificate', prependRun⟩ := primitive_prepend_run
        {ctx with escaped := union ctx.escaped before.facts.escapes} site it roots element certificate
        (union (liveCellsWith ctx.config aenv after) ctx.pinned) before
      rw [prependRun] at run
      have equal := Except.ok.inj run
      have first : Abstract.list (union [.site site 0] roots) (it.join element) certificate' = result :=
        congrArg Prod.fst equal
      have second : next = {before with facts := {before.facts with
          reads := union before.facts.reads (roots.filter external)}} := (congrArg Prod.snd equal).symm
      refine ⟨.listInt, ?_, by rw [second]; exact fun _ escaped => escaped⟩
      rw [← first]
      rcases flat_join_flat itemFlat elementFlat with joined | joined
      · rw [joined]; exact .listBottom _ _
      · rw [joined]; exact .listScalar _ _

end Ownership.FlatFragment.Static
