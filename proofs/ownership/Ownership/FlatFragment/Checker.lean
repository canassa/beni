import Ownership.FlatFragment.Support

/-! The first flat fragment: environment projections, binding facts, and the extraction of typing, shadow, atom, primitive, let, and scope facts from the actual checker runs. -/

/-! environment projection lemmas for the flat expression proof.
These lemmas follow the actual lookup and atom functions. A caller supplies
the prefix binding, not a final interpreter result or trace agreement. -/

namespace Ownership.FlatFragment.Env

open InPlaceSemantics Soundness

theorem lookup_map_values (env : Env α) (f : α → β) (key : Var) :
    (env.map fun (name, value) => (name, f value)).lookup key =
      (env.lookup key).map f := by
  induction env with
  | nil => rfl
  | cons entry env ih =>
    rcases entry with ⟨name, value⟩
    simp only [List.map_cons, List.lookup_cons]
    split <;> simp_all

theorem valueEnv_lookup {env : List (Var × Observation × Value)} {key : Var} {observation : Observation} {actual : Value}
    (found : env.lookup key = some (observation, actual)) :
    (valueEnv env).lookup key = some observation := by
  simpa [valueEnv, found] using lookup_map_values env Prod.fst key

theorem heapEnv_lookup {env : List (Var × Observation × Value)} {key : Var} {observation : Observation} {actual : Value}
    (found : env.lookup key = some (observation, actual)) :
    (heapEnv env).lookup key = some actual := by
  simpa [heapEnv, found] using lookup_map_values env Prod.snd key

theorem variable_atoms_run {env : List (Var × Observation × Value)} {key : Var} {observation : Observation} {actual : Value}
    (found : env.lookup key = some (observation, actual)) :
    ValueSemantics.atom (valueEnv env) (.var key) = .ok observation ∧
      InPlaceSemantics.atom (heapEnv env) (.var key) = .ok actual := by
  constructor
  · simp [ValueSemantics.atom, lookup, valueEnv_lookup found]
  · simp [InPlaceSemantics.atom, lookup, heapEnv_lookup found]

end Ownership.FlatFragment.Env

/-! variable facts from the actual prefix configuration.
Key alignment supplies the runtime binding. Live correspondence, abstract
description, and both runtime types come from the checked prefix relation.
No final execution or trace-agreement premise enters these lemmas. -/

namespace Ownership.FlatFragment.VariableFacts

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Env

theorem lookup_exists_of_same_keys (left : Env α) (right : Env β)
    (keys : left.map Prod.fst = right.map Prod.fst)
    (found : right.lookup key = some value) : ∃ actual, left.lookup key = some actual := by
  have present : (right.lookup key).isSome := by simp [found]
  obtain ⟨pair, member, equal⟩ := List.lookup_isSome_iff.mp present
  have rightKey : pair.1 ∈ right.map Prod.fst := List.mem_map.mpr ⟨pair, member, rfl⟩
  rw [← keys] at rightKey
  obtain ⟨actualPair, actualMember, sameName⟩ := List.mem_map.mp rightKey
  have actualEqual : key == actualPair.1 := by simpa only [sameName] using equal
  have actualPresent : (left.lookup key).isSome :=
    List.lookup_isSome_iff.mpr ⟨actualPair, actualMember, actualEqual⟩
  cases actual : left.lookup key with
  | none => simp [actual] at actualPresent
  | some value => exact ⟨value, rfl⟩

theorem runtime_binding_of_abstract
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (found : aenv.lookup key = some abstract) :
    ∃ observation actual, env.lookup key = some (observation, actual) := by
  obtain ⟨pair, binding⟩ := lookup_exists_of_same_keys env aenv inv.abstractKeys found
  exact ⟨pair.1, pair.2, binding⟩

theorem live_variable_result
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (use : (key, []) ∈ live)
    (binding : env.lookup key = some (observation, actual))
    (abstractBinding : aenv.lookup key = some abstract) :
    Corresponds hs.heap observation actual ∧ Describes gamma hs.heap abstract actual ∧
      ∃ type, tenv.lookup key = some type ∧ FlatType type ∧ FlatAbstract type abstract ∧
        obsTyped declarations observation type = true ∧ ValueTyped declarations hs.heap actual type := by
  obtain ⟨observed, value, observationPath, valuePath, paired⟩ :=
    inv.bindings key [] use observation actual binding
  simp only [projectObs, projectVal, Option.some.injEq] at observationPath valuePath
  cases observationPath
  cases valuePath
  have description := inv.described key [] use observation actual abstract actual binding abstractBinding rfl
  obtain ⟨type, declared, observationTyped, actualTyped⟩ :=
    inv.bindingsTyped key observation actual binding
  refine ⟨paired, ?_, type, declared, inv.types key type declared,
    inv.abstractShapes key type abstract declared abstractBinding, observationTyped, actualTyped⟩
  simpa only [Abstract.atPath] using description

end Ownership.FlatFragment.VariableFacts

/-! extraction lemmas for the flat ANF induction.

The lemmas retain the actual default checker acceptance equation. They
extract the ordinary typing and shadow checks that `check` executes.
The push lemma requires the actual list-shaped abstract operands and extracts
the real `demand` execution. It does not infer permission from a proxy check.
No theorem below uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.CheckerExtraction

open Soundness

theorem except_bind_success {action : Except String α}
    {next : α → Except String β}
    (run : (action >>= next) = .ok result) :
    ∃ intermediate, action = .ok intermediate ∧ next intermediate = .ok result := by
  cases first : action with
  | error problem =>
    rw [first] at run
    change Except.error problem = Except.ok result at run
    contradiction
  | ok intermediate =>
    exact ⟨intermediate, rfl, by simpa [first] using run⟩

/-- A successful `Except` map over a cons cell runs the head and the tail. -/
theorem except_mapM_cons_success {α : Type} {β : Type} {f : α → Except String β} {head : α} {tail : List α}
    {results : List β}
    (run : (head :: tail).mapM f = .ok results) :
    ∃ first rest, f head = .ok first ∧ tail.mapM f = .ok rest ∧ results = first :: rest := by
  rw [List.mapM_cons] at run
  obtain ⟨first, headRun, next⟩ := except_bind_success run
  obtain ⟨rest, tailRun, returned⟩ := except_bind_success next
  change Except.ok (first :: rest) = Except.ok results at returned
  exact ⟨first, rest, headRun, tailRun, (Except.ok.inj returned).symm⟩

theorem except_mapM_nil_success {α : Type} {β : Type} {f : α → Except String β} {results : List β}
    (run : ([] : List α).mapM f = .ok results) : results = [] := by
  rw [List.mapM_nil] at run
  change Except.ok [] = Except.ok results at run
  exact (Except.ok.inj run).symm

theorem except_mapM_cons {α : Type} {β : Type} {f : α → Except String β} {head : α} {tail : List α}
    {first : β} {rest : List β}
    (headRun : f head = .ok first) (tailRun : tail.mapM f = .ok rest) :
    (head :: tail).mapM f = .ok (first :: rest) := by
  rw [List.mapM_cons]
  simp [headRun, tailRun, bind, Except.bind, pure, Except.pure]

/-- A successful map is pointwise successful, and conversely. -/
theorem mapM_ok_fields {α β : Type} {f : α → Except String β} {xs : List α} {ys : List β}
    (run : xs.mapM f = .ok ys) :
    xs.length = ys.length ∧
      ∀ (i : Nat) (x : α) (y : β), xs[i]? = some x → ys[i]? = some y → f x = .ok y := by
  induction xs generalizing ys with
  | nil =>
    have := except_mapM_nil_success run
    subst this
    exact ⟨rfl, fun i x y h => by simp at h⟩
  | cons x xs ih =>
    obtain ⟨y, rest, headRun, tailRun, rfl⟩ := except_mapM_cons_success run
    obtain ⟨len, fields⟩ := ih tailRun
    refine ⟨by simp [len], ?_⟩
    intro i x' y' at_x at_y
    cases i with
    | zero =>
      simp at at_x at_y
      subst at_x; subst at_y
      exact headRun
    | succ i => exact fields i x' y' (by simpa using at_x) (by simpa using at_y)

theorem mapM_ok_of_fields {α β : Type} {f : α → Except String β} {xs : List α} {ys : List β}
    (len : xs.length = ys.length)
    (fields : ∀ (i : Nat) (x : α) (y : β), xs[i]? = some x → ys[i]? = some y → f x = .ok y) :
    xs.mapM f = .ok ys := by
  induction xs generalizing ys with
  | nil =>
    cases ys with
    | nil => rfl
    | cons _ _ => simp at len
  | cons x xs ih =>
    cases ys with
    | nil => simp at len
    | cons y ys =>
      have headRun : f x = .ok y := fields 0 x y rfl rfl
      have tailRun : xs.mapM f = .ok ys := ih (by simpa using len)
        (fun i x' y' at_x at_y => fields (i + 1) x' y' (by simpa using at_x) (by simpa using at_y))
      exact except_mapM_cons headRun tailRun

/-- The exact typing equation of a primitive expression. -/
theorem exprType_prim_success {args : List Atom} {op : Prim} {type : Ty} {self : Decl} {tenv : Env Ty} {declarations : List Decl}
    (run : exprType declarations self tenv (.prim op args) = .ok type) :
    ∃ types, args.mapM (atomType tenv) = .ok types ∧ primType op types = .ok type := by
  change (args.mapM (atomType tenv) >>= fun types => primType op types) = .ok type at run
  exact except_bind_success run

/-- A successful checker bind exposes its real intermediate state. -/
theorem checkM_bind_success {action : CheckM α} {next : α → CheckM β}
    (run : (action >>= next).run before = .ok (result, after)) :
    ∃ intermediate middle, action.run before = .ok (intermediate, middle) ∧
      (next intermediate).run middle = .ok (result, after) := by
  change (action before >>= fun (value, state) => next value state) = .ok (result, after) at run
  cases first : action before with
  | error problem =>
    rw [first] at run
    change Except.error problem = Except.ok (result, after) at run
    contradiction
  | ok pair =>
    rcases pair with ⟨intermediate, middle⟩
    exact ⟨intermediate, middle, first, by simpa [first] using run⟩

/-- Default acceptance runs the ordinary type checker, including its
shadow check. The result type comes from that exact successful execution. -/
theorem check_typecheck_success (accepted : check program = .ok result) :
    ∃ type, typecheck program = .ok type := by
  unfold check at accepted
  simp only [default_refuses_shadowing,
    Bool.false_eq_true, if_false] at accepted
  obtain ⟨type, typed, _⟩ := except_bind_success accepted
  exact ⟨type, typed⟩

/-- Ordinary typing returns the exact type of `typesOf` and also executes
the complete no-shadowing pass. -/
theorem typecheck_success_parts (run : typecheck program = .ok type) :
    typesOf program = .ok type ∧ noShadowing program = .ok () := by
  unfold typecheck at run
  obtain ⟨actualType, typed, rest⟩ := except_bind_success run
  obtain ⟨finished, shadow, returned⟩ := except_bind_success rest
  cases finished
  change Except.ok actualType = Except.ok type at returned
  cases returned
  exact ⟨typed, shadow⟩

/-- The final action of the real no-shadowing pass checks the main body. -/
theorem noShadowing_main_success (run : noShadowing program = .ok ()) :
    shadowFree [] program.main = .ok () := by
  unfold noShadowing at run
  obtain ⟨_, _, main⟩ := except_bind_success run
  exact main

/-- These equations come directly from the checks that accepted this
program. The declaration list remains unrestricted. -/
theorem check_main_type_and_shadow (accepted : check program = .ok result) :
    ∃ type,
      exprType program.declarations (mainDecl program.main) [] program.main = .ok type ∧
      shadowFree [] program.main = .ok () := by
  obtain ⟨type, typed⟩ := check_typecheck_success accepted
  exact ⟨type, typecheck_main program typed,
    noShadowing_main_success (typecheck_success_parts typed).2⟩

/-- Successful let typing supplies both exact child equations. The second
child uses the type that the first child actually returned. -/
theorem exprType_let_success
    (run : exprType declarations self env (.letE binder rhs rest) = .ok type) :
    ∃ rhsType,
      exprType declarations self env rhs = .ok rhsType ∧
      exprType declarations self ((binder, rhsType) :: env) rest = .ok type := by
  change (exprType declarations self env rhs >>= fun rhsType =>
    exprType declarations self ((binder, rhsType) :: env) rest) = .ok type at run
  exact except_bind_success run

/-- The successful let shadow check proves freshness and checks both child
scopes. The RHS retains the old scope; the continuation adds the binder. -/
theorem shadowFree_let_success
    (run : shadowFree bound (.letE binder rhs rest) = .ok ()) :
    bound.contains binder = false ∧ binder ∉ bound ∧
      shadowFree bound rhs = .ok () ∧ shadowFree (binder :: bound) rest = .ok () := by
  cases occupied : bound.contains binder with
  | true =>
    simp only [shadowFree, if_pos occupied] at run
    change Except.error _ = Except.ok () at run
    contradiction
  | false =>
    have fresh : binder ∉ bound := by
      intro member
      have present : bound.contains binder = true := List.contains_iff_mem.mpr member
      rw [occupied] at present
      contradiction
    have children :
        (shadowFree bound rhs >>= fun _ => shadowFree (binder :: bound) rest) = .ok () := by
      simpa [shadowFree, fresh] using run
    obtain ⟨_, first, second⟩ := except_bind_success children
    exact ⟨rfl, fresh, first, second⟩

/-- With the actual list-shaped operand, successful push inference runs the
actual demand. All operations after the demand are pure, so the demand
finishes in the primitive's exact final state. The configuration is general;
the default caller instantiates `ctx.config` with `{}`. -/
theorem primitive_push_demand_run
    (run : (primitive ctx site .push [.list roots element certificate, value] later).run before =
      .ok (result, after)) :
    (demand ctx.config roots later (union element.cells value.cells)).run before =
      .ok ((), after) := by
  unfold primitive at run
  obtain ⟨finished, middle, demanded, returned⟩ := checkM_bind_success run
  cases finished
  have same : middle = after := congrArg Prod.snd (Except.ok.inj returned)
  exact same ▸ demanded

/-- The explicit intermediate-state form is convenient for the generic
expression induction and the checked demand support. -/
theorem primitive_push_demand_witness
    (run : (primitive ctx site .push [.list roots element certificate, value] later).run before =
      .ok (result, after)) :
    ∃ middle,
      (demand ctx.config roots later (union element.cells value.cells)).run before =
        .ok ((), middle) :=
  ⟨after, primitive_push_demand_run run⟩

end Ownership.FlatFragment.CheckerExtraction

/-! extraction from the real accepted atom inference execution.
The conclusion gives the actual abstract atom lookup and unchanged facts.
It assumes no runtime success or final correspondence.
-/

namespace Ownership.FlatFragment.AtomInference

open Ownership.FlatFragment.CheckerExtraction

theorem infer_atom_success {inferenceFuel : Nat} {ctx : Context} {aenv : Env Abstract} {atom : Atom} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.atom atom) after site).run before =
      .ok (result, next)) :
    abstractAtom aenv atom = .ok result ∧ next = before := by
  cases inferenceFuel with
  | zero =>
    simp [inferExpr, bridgeObserve, defaultConfig, Config.has,
      StateT.run, StateT.bind, StateT.get, StateT.lift, Except.bind, Except.pure,
      StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set,
      liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ fuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts,
        scope, StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift,
        Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe,
        MonadStateOf.get, MonadStateOf.set, liftM, monadLift,
        MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
    | ok unit =>
      cases atomRun : abstractAtom aenv atom with
      | error problem =>
        simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts,
          scope, atomRun, StateT.run, StateT.bind, StateT.map, StateT.get,
          StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure,
          get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift,
          MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
      | ok abstract =>
        have computation :
            (inferExpr (fuel + 1) ctx aenv (.atom atom) after site).run before =
              .ok (abstract, before) := by
          simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts,
            scope, atomRun, StateT.run, StateT.bind, StateT.map, StateT.get,
            StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure,
            get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift,
            MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
        rw [computation] at accepted
        have equal := Except.ok.inj accepted
        exact ⟨congrArg Except.ok (congrArg Prod.fst equal),
          (congrArg Prod.snd equal).symm⟩

end Ownership.FlatFragment.AtomInference

/-! extraction of the actual default primitive inference step.
The operand premise is the real pure abstract-atom map, derived at callers.
Acceptance supplies the scope success and primitive execution, not a proxy
permission predicate or a final interpreter agreement.
-/

namespace Ownership.FlatFragment.PrimitiveInference

open Ownership.FlatFragment.CheckerExtraction

theorem infer_primitive_equation {ctx : Context} {aenv : Env Abstract} {args : List Atom} {abstracts : List Abstract} {after : Live} {site : List Nat} {before : St} {fuel : Nat} {op : Prim}
    (defaultConfig : ctx.config = {})
    (argsRun : args.mapM (m := Except String) (abstractAtom aenv) = .ok abstracts)
    (scope : liveScope aenv after = .ok ()) :
    (inferExpr (fuel + 1) ctx aenv (.prim op args) after site).run before =
      (primitive {ctx with escaped := union ctx.escaped before.facts.escapes} site op abstracts
        (union (liveCellsWith ctx.config aenv after) ctx.pinned)).run before := by
  simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts, scope, argsRun,
    StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind,
    Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
    MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
    MonadExceptOf.throw] <;> rfl

theorem infer_primitive_success {ctx : Context} {aenv : Env Abstract} {args : List Atom} {abstracts : List Abstract} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {inferenceFuel : Nat} {op : Prim}
    (defaultConfig : ctx.config = {})
    (argsRun : args.mapM (m := Except String) (abstractAtom aenv) = .ok abstracts)
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim op args) after site).run before =
      .ok (result, next)) :
    ∃ childFuel,
      inferenceFuel = childFuel + 1 ∧ liveScope aenv after = .ok () ∧
      (primitive {ctx with escaped := union ctx.escaped before.facts.escapes} site op abstracts
        (union (liveCellsWith ctx.config aenv after) ctx.pinned)).run before = .ok (result, next) := by
  cases inferenceFuel with
  | zero =>
    simp [inferExpr, bridgeObserve, defaultConfig, Config.has,
      StateT.run, StateT.bind, StateT.get, StateT.lift, Except.bind,
      Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
      MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
      MonadExceptOf.throw] at accepted
  | succ childFuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts, scope, argsRun,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind,
        Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
        MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
        MonadExceptOf.throw] at accepted
    | ok finished =>
      cases finished
      rw [infer_primitive_equation defaultConfig argsRun scope] at accepted
      exact ⟨childFuel, rfl, rfl, accepted⟩

/-- The operands of an accepted primitive ran: the checker reads them before the primitive. -/
theorem infer_primitive_args_success {ctx : Context} {aenv : Env Abstract} {args : List Atom} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {inferenceFuel : Nat} {op : Prim}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.prim op args) after site).run before =
      .ok (result, next)) :
    ∃ abstracts, args.mapM (m := Except String) (abstractAtom aenv) = .ok abstracts := by
  cases inferenceFuel with
  | zero =>
    simp [inferExpr, bridgeObserve, defaultConfig, Config.has,
      StateT.run, StateT.bind, StateT.get, StateT.lift, Except.bind,
      Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
      MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
      MonadExceptOf.throw] at accepted
  | succ childFuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts, scope,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind,
        Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
        MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
        MonadExceptOf.throw] at accepted
    | ok finished =>
      cases finished
      cases argsRun : args.mapM (m := Except String) (abstractAtom aenv) with
      | error problem =>
        simp [inferExpr, bridgeObserve, defaultConfig, Config.has, getFacts, scope, argsRun,
          StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind,
          Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get,
          MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe,
          MonadExceptOf.throw] at accepted
      | ok abstracts => exact ⟨abstracts, rfl⟩

end Ownership.FlatFragment.PrimitiveInference

/-! extraction of the actual default let inference execution.
No theorem uses a pinned soundness obligation.

The context retains its general escaped and pinned sets. The theorem derives
both child executions and the real live-scope success from the complete run.
The explicit outer-empty premise selects the ordinary continuation branch.
No final-state equality or child-success premise enters.
-/

namespace Ownership.FlatFragment.InferLet

open Ownership.FlatFragment.CheckerExtraction

/-- One actual let inference step first checks the live scope. It then
runs the RHS and continuation with the exact contexts and sites in Checker;
the continuation's context records the binder's callback-chain depth.
The first read of the checker facts leaves the checker state unchanged.
-/
theorem infer_let_succ_equation {ctx : Context} {binder : Var} {after : Live}
    (defaultConfig : ctx.config = {})
    (outerEmpty : after.filter (fun use => use.1 == binder) = []) :
    let updated : Context :=
      {ctx with escaped := union ctx.escaped before.facts.escapes}
    let rhsCtx : Context :=
      {updated with privateTransfer := match rhs with
        | .prim .privateRoot _ => privateToInit binder rest
        | _ => false}
    let continued : Context :=
      {updated with chain := (binder, rhsChain ctx.chain (match rhs with
        | .app callee _ => ((abstractAtom aenv callee) matches .ok (.symbolic ..))
        | _ => false) rhs) :: ctx.chain}
    (inferExpr (fuel + 1) ctx aenv (.letE binder rhs rest) after site).run before =
      (liveScope aenv after >>= fun _ =>
        ((inferExpr fuel rhsCtx aenv rhs
          (union after (removeVars [binder] (usesWith ctx.config rest))) (site ++ [0])) >>= fun value =>
          inferExpr fuel continued ((binder, value) :: aenv) rest after (site ++ [1])).run before) := by
  dsimp only
  rw [inferExpr]
  cases scope : liveScope aenv after with
  | error problem =>
    simp [bridgeObserve, defaultConfig, Config.has, getFacts, outerEmpty, scope,
      StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
  | ok unit =>
    cases unit
    simp [bridgeObserve, defaultConfig, Config.has, getFacts, outerEmpty, scope,
      StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    rfl

/-- Successful default inference cannot use zero inference fuel. Its real
prefix supplies the live-scope success and exact intermediate checker state.
The RHS private-transfer flag matches the actual private-root selection.
The continuation preserves every pre-existing pinned origin.
-/
theorem infer_let_success {ctx : Context} {aenv : Env Abstract} {binder : Var} {rhs : Expr} {rest : Expr} {after : Live} {site : List Nat} {before : St} {next : St} {result : Abstract} {inferenceFuel : Nat}
    (defaultConfig : ctx.config = {})
    (outerEmpty : after.filter (fun use => use.1 == binder) = [])
    (accepted : (inferExpr inferenceFuel ctx aenv (.letE binder rhs rest) after site).run before =
      .ok (result, next)) :
    ∃ childFuel value middle,
      inferenceFuel = childFuel + 1 ∧ liveScope aenv after = .ok () ∧
      let updated : Context :=
        {ctx with escaped := union ctx.escaped before.facts.escapes}
      let rhsCtx : Context :=
        {updated with privateTransfer := match rhs with
          | .prim .privateRoot _ => privateToInit binder rest
          | _ => false}
      let continued : Context :=
        {updated with chain := (binder, rhsChain ctx.chain (match rhs with
          | .app callee _ => ((abstractAtom aenv callee) matches .ok (.symbolic ..))
          | _ => false) rhs) :: ctx.chain}
      (inferExpr childFuel rhsCtx aenv rhs
        (union after (removeVars [binder] (usesWith ctx.config rest))) (site ++ [0])).run before =
          .ok (value, middle) ∧
      (inferExpr childFuel continued ((binder, value) :: aenv) rest after (site ++ [1])).run middle =
          .ok (result, next) := by
  cases inferenceFuel with
  | zero =>
    rw [inferExpr] at accepted
    simp [bridgeObserve, defaultConfig, Config.has, StateT.run,
      StateT.bind, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ childFuel =>
    have expanded := infer_let_succ_equation (fuel := childFuel)
      (before := before) (rhs := rhs) (rest := rest) (site := site)
      (aenv := aenv) defaultConfig outerEmpty
    rw [expanded] at accepted
    obtain ⟨unit, scope, children⟩ := except_bind_success accepted
    cases unit
    obtain ⟨value, middle, rhsRun, restRun⟩ := checkM_bind_success children
    exact ⟨childFuel, value, middle, rfl, scope, rhsRun, restRun⟩

end Ownership.FlatFragment.InferLet

/-! extraction of the actual default branch inference execution.
No theorem uses a pinned soundness obligation.

The checker reads its facts, infers the first arm, restores the facts,
infers the second arm from the first arm's state with the restored facts,
and records the join of both arms' facts and results. -/

namespace Ownership.FlatFragment.InferBranch

open Ownership.FlatFragment.CheckerExtraction

theorem modifyFacts_run (f : Summary → Summary) (before : St) :
    (modifyFacts f).run before = .ok ((), {before with facts := f before.facts}) := rfl

theorem infer_branch_succ_equation {ctx : Context} {aenv : Env Abstract} {c : Atom} {yes no : Expr} {after : Live} {site : List Nat} {before : St} {fuel : Nat}
    (defaultConfig : ctx.config = {}) :
    let updated : Context := {ctx with escaped := union ctx.escaped before.facts.escapes}
    (inferExpr (fuel + 1) ctx aenv (.branch c yes no) after site).run before =
      (liveScope aenv after >>= fun _ => abstractAtom aenv c >>= fun _ =>
        ((inferExpr fuel updated aenv yes after (site ++ [0])) >>= fun a =>
          getFacts >>= fun left => modifyFacts (fun _ => before.facts) >>= fun _ =>
          inferExpr fuel updated aenv no after (site ++ [1]) >>= fun b =>
          getFacts >>= fun right => modifyFacts (fun _ => left.join right) >>= fun _ =>
          pure (a.join b)).run before) := by
  dsimp only
  rw [inferExpr]
  cases scope : liveScope aenv after with
  | error problem =>
    simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope,
      StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
  | ok unit =>
    cases unit
    cases atomRun : abstractAtom aenv c with
    | error problem =>
      simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope, atomRun,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
    | ok ca =>
      simp [bridgeObserve, defaultConfig, Config.has, getFacts, modifyFacts, scope, atomRun,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, modify, modifyGet, MonadStateOf.modifyGet]

theorem infer_branch_success {ctx : Context} {aenv : Env Abstract} {c : Atom} {yes no : Expr} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel : Nat}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.branch c yes no) after site).run before =
      .ok (result, next)) :
    ∃ (childFuel : Nat) (a : Abstract) (middle : St) (b : Abstract) (last : St),
      inferenceFuel = childFuel + 1 ∧ liveScope aenv after = .ok () ∧
      (∃ ca, abstractAtom aenv c = .ok ca) ∧
      let updated : Context := {ctx with escaped := union ctx.escaped before.facts.escapes}
      (inferExpr childFuel updated aenv yes after (site ++ [0])).run before = .ok (a, middle) ∧
      (inferExpr childFuel updated aenv no after (site ++ [1])).run
        {middle with facts := before.facts} = .ok (b, last) ∧
      result = a.join b ∧ next = {last with facts := middle.facts.join last.facts} := by
  cases inferenceFuel with
  | zero =>
    rw [inferExpr] at accepted
    simp [bridgeObserve, defaultConfig, StateT.run,
      StateT.bind, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ childFuel =>
    rw [infer_branch_succ_equation defaultConfig] at accepted
    obtain ⟨finished, scope, rest⟩ := except_bind_success accepted
    cases finished
    obtain ⟨ca, atomRun, rest⟩ := except_bind_success rest
    obtain ⟨a, middle, yesRun, rest⟩ := checkM_bind_success rest
    obtain ⟨left, middle', leftRun, rest⟩ := checkM_bind_success rest
    have leftEq : left = middle.facts ∧ middle = middle' := by
      have := Except.ok.inj leftRun
      exact ⟨(congrArg Prod.fst this).symm, congrArg Prod.snd this⟩
    obtain ⟨rfl, rfl⟩ := leftEq
    obtain ⟨finished, restored, restoredRun, rest⟩ := checkM_bind_success rest
    cases finished
    rw [modifyFacts_run] at restoredRun
    have restoredEq : restored = {middle with facts := before.facts} :=
      (congrArg Prod.snd (Except.ok.inj restoredRun)).symm
    subst restoredEq
    obtain ⟨b, last, noRun, rest⟩ := checkM_bind_success rest
    obtain ⟨right, last', rightRun, rest⟩ := checkM_bind_success rest
    have rightEq : right = last.facts ∧ last = last' := by
      have := Except.ok.inj rightRun
      exact ⟨(congrArg Prod.fst this).symm, congrArg Prod.snd this⟩
    obtain ⟨rfl, rfl⟩ := rightEq
    obtain ⟨finished, joined, joinedRun, rest⟩ := checkM_bind_success rest
    cases finished
    rw [modifyFacts_run] at joinedRun
    have joinedEq : joined = {last with facts := middle.facts.join last.facts} :=
      (congrArg Prod.snd (Except.ok.inj joinedRun)).symm
    subst joinedEq
    have final := Except.ok.inj rest
    exact ⟨childFuel, a, middle, b, last, rfl, scope, ⟨ca, atomRun⟩, yesRun, noRun,
      (congrArg Prod.fst final).symm, (congrArg Prod.snd final).symm⟩

end Ownership.FlatFragment.InferBranch

/-! extraction of the actual default result-case inference execution.
The input's abstract is a record of a tag and two slots. The checker infers
an arm only when its slot is not bottom, from the incoming facts, restores
them between the arms, and joins the arms' results and facts. -/

namespace Ownership.FlatFragment.InferResultCase

open Ownership.FlatFragment.CheckerExtraction Ownership.FlatFragment.InferBranch

theorem record_three_ne_bottom (tag ae aa : Abstract) :
    ((Abstract.record [tag, ae, aa]) == .bottom) = false := by
  simp [BEq.beq, Abstract.equal]

theorem infer_resultCase_succ_equation {ctx : Context} {aenv : Env Abstract} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {after : Live} {site : List Nat} {before : St} {fuel : Nat} {tag ae aa : Abstract}
    (defaultConfig : ctx.config = {})
    (atomRun : abstractAtom aenv input = .ok (.record [tag, ae, aa])) :
    let updated : Context := {ctx with escaped := union ctx.escaped before.facts.escapes}
    (inferExpr (fuel + 1) ctx aenv (.resultCase input err ok onError onSuccess) after site).run before =
      (liveScope aenv after >>= fun _ =>
        (getFacts >>= fun incoming =>
          (if ae == .bottom then pure .bottom
            else inferExpr fuel updated ((err, ae) :: aenv) onError after (site ++ [0])) >>= fun left =>
          getFacts >>= fun leftFacts => modifyFacts (fun _ => incoming) >>= fun _ =>
          (if aa == .bottom then pure .bottom
            else inferExpr fuel updated ((ok, aa) :: aenv) onSuccess after (site ++ [1])) >>= fun right =>
          getFacts >>= fun rightFacts => modifyFacts (fun _ => leftFacts.join rightFacts) >>= fun _ =>
          pure (left.join right)).run before) := by
  dsimp only
  rw [inferExpr]
  cases scope : liveScope aenv after with
  | error problem =>
    simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope,
      StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw]
  | ok unit =>
    cases unit
    by_cases bottomE : (ae == Abstract.bottom) = true <;> by_cases bottomS : (aa == Abstract.bottom) = true <;>
      simp [bridgeObserve, defaultConfig, Config.has, getFacts, modifyFacts, scope, atomRun,
        record_three_ne_bottom, bottomE, bottomS,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, modify, modifyGet, MonadStateOf.modifyGet]

/-- The input of an accepted result case ran. -/
theorem infer_resultCase_atom_success {ctx : Context} {aenv : Env Abstract} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel : Nat}
    (defaultConfig : ctx.config = {})
    (accepted : (inferExpr inferenceFuel ctx aenv (.resultCase input err ok onError onSuccess) after site).run before =
      .ok (result, next)) :
    ∃ value, abstractAtom aenv input = .ok value := by
  cases inferenceFuel with
  | zero =>
    rw [inferExpr] at accepted
    simp [bridgeObserve, defaultConfig, StateT.run,
      StateT.bind, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ childFuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      rw [inferExpr] at accepted
      simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
    | ok unit =>
      cases unit
      cases atomRun : abstractAtom aenv input with
      | error problem =>
        rw [inferExpr] at accepted
        simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope, atomRun,
          StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
      | ok value => exact ⟨value, rfl⟩

theorem bottom_beq_bottom : ((Abstract.bottom) == .bottom) = true := by
  simp [BEq.beq, Abstract.equal]

/-- A case on a dead input (its abstract bottom) returns bottom and changes nothing. -/
theorem infer_resultCase_bottom_success {ctx : Context} {aenv : Env Abstract} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel : Nat}
    (defaultConfig : ctx.config = {})
    (atomRun : abstractAtom aenv input = .ok .bottom)
    (accepted : (inferExpr inferenceFuel ctx aenv (.resultCase input err ok onError onSuccess) after site).run before =
      .ok (result, next)) :
    result = .bottom ∧ next = before := by
  cases inferenceFuel with
  | zero =>
    rw [inferExpr] at accepted
    simp [bridgeObserve, defaultConfig, StateT.run,
      StateT.bind, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ childFuel =>
    cases scope : liveScope aenv after with
    | error problem =>
      rw [inferExpr] at accepted
      simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
    | ok unit =>
      cases unit
      rw [inferExpr] at accepted
      simp [bridgeObserve, defaultConfig, Config.has, getFacts, scope, atomRun, bottom_beq_bottom,
        StateT.run, StateT.bind, StateT.map, StateT.get, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
      exact ⟨accepted.1.symm, accepted.2.symm⟩

/-- A skipped arm leaves its result bottom and its state untouched; an
inferred arm runs from the incoming facts. -/
theorem infer_resultCase_success {ctx : Context} {aenv : Env Abstract} {input : Atom} {err ok : Var} {onError onSuccess : Expr} {after : Live} {site : List Nat} {before next : St} {result : Abstract} {inferenceFuel : Nat} {tag ae aa : Abstract}
    (defaultConfig : ctx.config = {})
    (atomRun : abstractAtom aenv input = .ok (.record [tag, ae, aa]))
    (accepted : (inferExpr inferenceFuel ctx aenv (.resultCase input err ok onError onSuccess) after site).run before =
      .ok (result, next)) :
    ∃ (childFuel : Nat) (left : Abstract) (middle : St) (right : Abstract) (last : St),
      inferenceFuel = childFuel + 1 ∧ liveScope aenv after = .ok () ∧
      let updated : Context := {ctx with escaped := union ctx.escaped before.facts.escapes}
      ((ae == .bottom) = true ∧ left = .bottom ∧ middle = before ∨
        (ae == .bottom) = false ∧
          (inferExpr childFuel updated ((err, ae) :: aenv) onError after (site ++ [0])).run before =
            .ok (left, middle)) ∧
      ((aa == .bottom) = true ∧ right = .bottom ∧ last = {middle with facts := before.facts} ∨
        (aa == .bottom) = false ∧
          (inferExpr childFuel updated ((ok, aa) :: aenv) onSuccess after (site ++ [1])).run
            {middle with facts := before.facts} = .ok (right, last)) ∧
      result = left.join right ∧ next = {last with facts := middle.facts.join last.facts} := by
  cases inferenceFuel with
  | zero =>
    rw [inferExpr] at accepted
    simp [bridgeObserve, defaultConfig, StateT.run,
      StateT.bind, StateT.lift, Except.bind, Except.pure, StateT.pure, bind, pure, get, getThe, MonadStateOf.get, MonadStateOf.set, liftM, monadLift, MonadLift.monadLift, throw, throwThe, MonadExceptOf.throw] at accepted
  | succ childFuel =>
    rw [infer_resultCase_succ_equation defaultConfig atomRun] at accepted
    obtain ⟨finished, scope, rest⟩ := except_bind_success accepted
    cases finished
    obtain ⟨incoming, before', incomingRun, rest⟩ := checkM_bind_success rest
    have incomingEq : incoming = before.facts ∧ before = before' := by
      have := Except.ok.inj incomingRun
      exact ⟨(congrArg Prod.fst this).symm, congrArg Prod.snd this⟩
    obtain ⟨rfl, rfl⟩ := incomingEq
    obtain ⟨left, middle, leftRun, rest⟩ := checkM_bind_success rest
    obtain ⟨leftFacts, middle', leftFactsRun, rest⟩ := checkM_bind_success rest
    have leftEq : leftFacts = middle.facts ∧ middle = middle' := by
      have := Except.ok.inj leftFactsRun
      exact ⟨(congrArg Prod.fst this).symm, congrArg Prod.snd this⟩
    obtain ⟨rfl, rfl⟩ := leftEq
    obtain ⟨finished, restored, restoredRun, rest⟩ := checkM_bind_success rest
    cases finished
    rw [modifyFacts_run] at restoredRun
    have restoredEq : restored = {middle with facts := before.facts} :=
      (congrArg Prod.snd (Except.ok.inj restoredRun)).symm
    subst restoredEq
    obtain ⟨right, last, rightRun, rest⟩ := checkM_bind_success rest
    obtain ⟨rightFacts, last', rightFactsRun, rest⟩ := checkM_bind_success rest
    have rightEq : rightFacts = last.facts ∧ last = last' := by
      have := Except.ok.inj rightFactsRun
      exact ⟨(congrArg Prod.fst this).symm, congrArg Prod.snd this⟩
    obtain ⟨rfl, rfl⟩ := rightEq
    obtain ⟨finished, joined, joinedRun, rest⟩ := checkM_bind_success rest
    cases finished
    rw [modifyFacts_run] at joinedRun
    have joinedEq : joined = {last with facts := middle.facts.join last.facts} :=
      (congrArg Prod.snd (Except.ok.inj joinedRun)).symm
    subst joinedEq
    have final := Except.ok.inj rest
    refine ⟨childFuel, left, middle, right, last, rfl, scope, ?_, ?_,
      (congrArg Prod.fst final).symm, (congrArg Prod.snd final).symm⟩
    · cases bottom : (ae == .bottom) with
      | true =>
        rw [if_pos bottom] at leftRun
        have := Except.ok.inj leftRun
        exact Or.inl ⟨rfl, (congrArg Prod.fst this).symm, (congrArg Prod.snd this).symm⟩
      | false =>
        rw [if_neg (by simp [bottom])] at leftRun
        exact Or.inr ⟨rfl, leftRun⟩
    · cases bottom : (aa == .bottom) with
      | true =>
        rw [if_pos bottom] at rightRun
        have := Except.ok.inj rightRun
        exact Or.inl ⟨rfl, (congrArg Prod.fst this).symm, (congrArg Prod.snd this).symm⟩
      | false =>
        rw [if_neg (by simp [bottom])] at rightRun
        exact Or.inr ⟨rfl, rightRun⟩

end Ownership.FlatFragment.InferResultCase

/-! scope facts from the actual successful checker scope test.
Shadow freshness and prefix key alignment exclude the let binder from the
outer continuation. This derives the branch premise used by let extraction.
-/

namespace Ownership.FlatFragment.Scope

theorem lookup_key_member {env : Env α} {key : Var} {value : α} (found : env.lookup key = some value) :
    key ∈ env.map Prod.fst := by
  have present : (env.lookup key).isSome := by simp [found]
  obtain ⟨entry, member, equal⟩ := List.lookup_isSome_iff.mp present
  have same : key = entry.1 := by simpa using equal
  subst key
  exact List.mem_map.mpr ⟨entry, member, rfl⟩

theorem liveScope_lookup_exists {aenv : Env Abstract} {live : Live} {use : Var × Path}
    (scope : liveScope aenv live = .ok ()) (member : use ∈ live) :
    ∃ abstract, aenv.lookup use.1 = some abstract := by
  cases search : live.find? (fun (key, _) => (aenv.lookup key).isNone) with
  | some entry =>
    rcases entry with ⟨key, path⟩
    simp [liveScope, search] at scope
  | none =>
    have present := List.find?_eq_none.mp search use member
    cases found : aenv.lookup use.1 with
    | none => simp [found] at present
    | some abstract => exact ⟨abstract, rfl⟩

theorem outer_avoids_fresh_binder {env : Env α} {aenv : Env Abstract} {binder : Var} {after : Live}
    (keys : env.map Prod.fst = aenv.map Prod.fst)
    (fresh : binder ∉ env.map Prod.fst)
    (scope : liveScope aenv after = .ok ()) :
    after.filter (fun use => use.1 == binder) = [] := by
  apply List.filter_eq_nil_iff.mpr
  intro use member
  have different : use.1 ≠ binder := by
    intro same
    obtain ⟨abstract, found⟩ := liveScope_lookup_exists scope member
    have present : use.1 ∈ env.map Prod.fst := by
      rw [keys]
      exact lookup_key_member found
    exact fresh (by simpa [same] using present)
  simp [different]

end Ownership.FlatFragment.Scope
