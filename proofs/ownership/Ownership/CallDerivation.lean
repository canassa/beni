-- Last link of the proof import chain: this module imports the fragment's
-- trace module, so it sees every earlier realization of an equation lemma
-- (#182). The root imports it after `FlatFragment.Trace`.
import Ownership.FlatFragment.Trace

/-! The caller-side derivation of the summary theorems' written-storage
premise (#169): at an accepted first-order call without captures, the
call-site invariant and the call's own demands give `LinkedWritesCovered`.
`applyCall` demands every published write and consume row against the live
cells after the call and the other operand paths; the operands are live, so
`Invariant.described` names each input array at every path by the actual's
cells; `linkNamed` makes a linked input array share the written array's
origins; and the Disjoint test refuses the overlap. No theorem here uses a
pinned obligation. Calls with captures and calls with function-valued
inputs (the `env` and `calls` rows) are not covered.

Two notes on the main statement. The hypothesis `known` (no `unknown` cell
on any actual) is stronger than the Known test, which checks the written
cells only; the call case of `invariant_preserved` must establish it on its
own, and it is a residual obligation (`PROOF-PLAN.md`, *Summary pre-state
links and validity*). The trailing argument `ins` is unused: the lemma holds
for any canonical input list, and the argument only matches the signature of
`LinkedWritesCovered`. -/

namespace Ownership.CallDerivation

open Ownership.FlatFragment.Fields

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.Support
  Ownership.FlatFragment.NamingFacts

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- Bind success in the checker's monad. -/
theorem checkM_bind_success {α β : Type} {action : CheckM α} {next : α → CheckM β}
    {before after : St} {value : β}
    (run : (action >>= next).run before = .ok (value, after)) :
    ∃ intermediate middle, action.run before = .ok (intermediate, middle) ∧
      (next intermediate).run middle = .ok (value, after) := by
  change (action before >>= fun (a, s) => next a s) = .ok (value, after) at run
  cases first : action before with
  | error problem =>
    rw [first] at run
    change Except.error problem = Except.ok (value, after) at run
    contradiction
  | ok pair =>
    rcases pair with ⟨intermediate, middle⟩
    exact ⟨intermediate, middle, first, by simpa [first] using run⟩

/-- A successful default demand keeps the recorded escapes. -/
theorem demand_escapes {cs later others : List Origin} {before after : St} {u : Unit}
    (run : (demand ({} : Config) cs later others).run before = .ok (u, after)) :
    after.facts.escapes = before.facts.escapes := by
  have problem := demand_success_problem run
  dsimp [demand, getFacts, modifyFacts, StateT.run, StateT.bind, StateT.map, StateT.get,
    modify, modifyGet, StateT.modifyGet] at run
  simp only [pure_bind, problem] at run
  change Except.ok ((), _) = Except.ok (u, after) at run
  cases run
  rfl

/-- Every row of a successful demand loop passed its test against the
    escapes recorded before the loop. -/
theorem forIn_demands (items : List Origin) (cells others : Origin → List Origin)
    (later : List Origin) {before after : St} {u : PUnit}
    (run : (forIn (m := CheckM) items PUnit.unit (fun w (_ : PUnit) => do
        demand ({} : Config) (cells w) later (others w)
        pure (ForInStep.yield PUnit.unit))).run before = .ok (u, after)) :
    after.facts.escapes = before.facts.escapes ∧
      ∀ w ∈ items, demandProblem ({} : Config) before.facts.escapes (cells w) later (others w) = none := by
  induction items generalizing before with
  | nil =>
    rw [List.forIn_nil] at run
    change Except.ok (PUnit.unit, before) = Except.ok (u, after) at run
    cases run
    exact ⟨rfl, by intro w member; simp at member⟩
  | cons item items ih =>
    rw [List.forIn_cons] at run
    obtain ⟨step, middle, stepRun, rest⟩ := checkM_bind_success run
    obtain ⟨_, afterDemand, demandRun, yieldRun⟩ := checkM_bind_success stepRun
    change Except.ok (ForInStep.yield PUnit.unit, afterDemand) = Except.ok (step, middle) at yieldRun
    cases yieldRun
    have escapes := demand_escapes demandRun
    have problem := demand_success_problem demandRun
    change (forIn (m := CheckM) items PUnit.unit _).run _ = Except.ok (u, after) at rest
    obtain ⟨escapesRest, all⟩ := ih rest
    refine ⟨escapesRest.trans escapes, ?_⟩
    intro w member
    simp only [List.mem_cons] at member
    rcases member with rfl | member
    · exact problem
    · rw [← escapes]
      exact all w member

/-- The default configuration keeps the callee's captures as operand paths.
    Both `rfl` facts below hold by the default `Config` (`mutant := none`); a
    changed default breaks them loudly. -/
theorem default_no_calleeCapture : ({} : Config).has .calleeCapture = false := rfl

/-- Every write and consume row of a successful default `applyCall` passed
    its demand against the escapes recorded before the call, the live cells
    after it, and the other operand paths. -/
theorem applyCall_demands {ctx : Context} (config : ctx.config = {}) {s : Summary}
    {site : List Nat} {args caps : List Abstract} {later : List Origin}
    {before after : St} {result : Abstract}
    (run : (applyCall ctx s site args caps later).run before = .ok (result, after)) :
    ∀ w ∈ s.writes ++ s.consumes,
      demandProblem ({} : Config) before.facts.escapes (instantiateOrigin site args caps w) later
        (otherPaths args caps w) = none := by
  unfold applyCall at run
  rw [config] at run
  simp only [default_no_calleeCapture, Bool.false_eq_true, if_false] at run
  obtain ⟨_, middle, loopRun, _⟩ := checkM_bind_success run
  exact (forIn_demands (s.writes ++ s.consumes) (fun w => instantiateOrigin site args caps w)
    (fun w => otherPaths args caps w) later loopRun).2

/-- A value found at a path is reached. -/
theorem atPath_reaches {heap : Heap} {v : Value} {q : Path} {w : Value}
    (h : AtPath heap v q w) : Reaches heap v w := by
  induction h with
  | here v => exact Reaches.refl v
  | element lookup mem _ ih => exact Reaches.element lookup mem ih
  | field lookup _ ih => exact Reaches.field (List.mem_of_getElem? lookup) ih
  | capture lookup _ ih => exact Reaches.capture (List.mem_of_getElem? lookup) ih
  | env mem reaches => exact Reaches.capture mem reaches

/-- A parameter row at a path that is not an environment path instantiates
    to the argument's cells at that path. -/
theorem instantiateOrigin_parameter (site : List Nat) (args caps : List Abstract) (i : Nat)
    (q : Path) (notEnv : ∀ rest, q ≠ .env :: rest) :
    instantiateOrigin site args caps (.parameter i q) = (args[i]?.getD .bottom).cellsAt q := by
  cases q with
  | nil => rfl
  | cons step rest =>
    cases step with
    | env => exact absurd rfl (notEnv rest)
    | field _ => rfl
    | element => rfl
    | capture _ => rfl

/-- Every cell at another operand path is among the other paths of a
    parameter row that is not an environment path. -/
theorem mem_otherPaths (args caps : List Abstract) (i j : Nat) (q p : Path) (a : Abstract)
    (cs : List Origin) (o' : Origin) (notEnv : ∀ rest, q ≠ .env :: rest)
    (lookup : args[j]? = some a) (path : (p, cs) ∈ a.paths) (member : o' ∈ cs)
    (different : (j, p) ≠ (i, q)) :
    o' ∈ otherPaths args caps (.parameter i q) := by
  unfold otherPaths
  dsimp only
  refine List.mem_flatMap.mpr ⟨(.parameter j p, cs), List.mem_append.mpr (Or.inl ?_), ?_⟩
  · exact List.mem_flatMap.mpr ⟨(a, j), List.mk_mem_zipIdx_iff_getElem?.mpr lookup,
      List.mem_map.mpr ⟨(p, cs), path, rfl⟩⟩
  · have ne : (Origin.parameter j p == Origin.parameter i q) = false := by
      rw [beq_eq_false_iff_ne]
      intro h
      cases h
      exact different rfl
    cases q with
    | nil => simp [ne, member]
    | cons step rest =>
      cases step with
      | env => exact absurd rfl (notEnv rest)
      | field _ => simp [ne, member]
      | element => simp [ne, member]
      | capture _ => simp [ne, member]

/-- An element path of a list's element abstract is a path of the list. -/
theorem list_path_mem (cs : List Origin) (x : Abstract) (ex : Certificate) (p : Path)
    (ds : List Origin) (path : (p, ds) ∈ x.paths) :
    (.element :: p, ds) ∈ (Abstract.list cs x ex).paths := by
  simp only [Abstract.paths]
  exact List.mem_cons_of_mem _ (List.mem_map.mpr ⟨(p, ds), path, rfl⟩)

/-- A component of a first-order record is first-order. -/
theorem record_component_firstOrder (xs : List Abstract) (i : Nat) (x : Abstract)
    (lookup : xs[i]? = some x) (firstOrder : hasFunction (.record xs) = false) :
    hasFunction x = false := by
  simp only [hasFunction, List.any_eq_false] at firstOrder
  have := firstOrder ⟨x, List.mem_of_getElem? lookup⟩ (List.mem_attach _ _)
  simpa using this

/-- The names at a path of a first-order abstract are drawn from its paths. -/
theorem namesAt_mem_paths (q : Path) (a : Abstract) (o : Origin) (member : o ∈ namesAt a q)
    (firstOrder : hasFunction a = false) :
    ∃ p cs, (p, cs) ∈ a.paths ∧ o ∈ cs := by
  induction q generalizing a with
  | nil =>
    obtain ⟨cs, path, inCs⟩ := mem_cellsAt a [] o member
    exact ⟨[], cs, path, inCs⟩
  | cons step rest ih =>
    cases a with
    | bottom => simp [namesAt] at member
    | scalar => simp [namesAt] at member
    | function _ _ => simp [hasFunction] at firstOrder
    | symbolic _ _ _ _ => simp [hasFunction] at firstOrder
    | record xs =>
      cases step with
      | field i =>
        simp only [namesAt] at member
        cases lookup : xs[i]? with
        | none =>
          rw [lookup] at member
          cases rest <;> simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
        | some x =>
          rw [lookup] at member
          simp only [Option.getD_some] at member
          obtain ⟨p, cs, path, inCs⟩ :=
            ih x member (record_component_firstOrder xs i x lookup firstOrder)
          exact ⟨.field i :: p, cs, record_path_mem xs i x p cs lookup path, inCs⟩
      | element => simp [namesAt] at member
      | capture _ => simp [namesAt] at member
      | env => simp [namesAt] at member
    | list cs x ex =>
      have firstOrderX : hasFunction x = false := by simpa [hasFunction] using firstOrder
      cases step with
      | element =>
        simp only [namesAt] at member
        by_cases unknown : cs.contains .unknown = true
        · rw [if_pos unknown] at member
          exact ⟨[], cs, by simp [Abstract.paths], member⟩
        · rw [if_neg unknown] at member
          obtain ⟨p, ds, path, inDs⟩ := ih x member firstOrderX
          exact ⟨.element :: p, ds, list_path_mem cs x ex p ds path, inDs⟩
      | field _ =>
        simp only [namesAt] at member
        by_cases unknown : cs.contains .unknown = true
        · rw [if_pos unknown] at member
          exact ⟨[], cs, by simp [Abstract.paths], member⟩
        · rw [if_neg unknown] at member
          simp at member
      | capture _ =>
        simp only [namesAt] at member
        by_cases unknown : cs.contains .unknown = true
        · rw [if_pos unknown] at member
          exact ⟨[], cs, by simp [Abstract.paths], member⟩
        · rw [if_neg unknown] at member
          simp at member
      | env =>
        simp only [namesAt] at member
        by_cases unknown : cs.contains .unknown = true
        · rw [if_pos unknown] at member
          exact ⟨[], cs, by simp [Abstract.paths], member⟩
        · rw [if_neg unknown] at member
          simp at member

/-! ## Names at a path of a first-order, known abstract -/

theorem default_no_disjoint : ({} : Config).has .disjoint = false := rfl

/-- An origin among the names at a path of a first-order, known abstract is
    recorded exactly at that path. -/
theorem namesAt_mem_paths_exact (q : Path) (a : Abstract) (o : Origin) (member : o ∈ namesAt a q)
    (firstOrder : hasFunction a = false) (known : ∀ entry ∈ a.paths, Origin.unknown ∉ entry.2) :
    ∃ cs, (q, cs) ∈ a.paths ∧ o ∈ cs := by
  induction q generalizing a with
  | nil => exact mem_cellsAt a [] o member
  | cons step rest ih =>
    cases a with
    | bottom => simp [namesAt] at member
    | scalar => simp [namesAt] at member
    | function _ _ => simp [hasFunction] at firstOrder
    | symbolic _ _ _ _ => simp [hasFunction] at firstOrder
    | record xs =>
      cases step with
      | field i =>
        simp only [namesAt] at member
        cases lookup : xs[i]? with
        | none =>
          rw [lookup] at member
          cases rest <;> simp [namesAt, Abstract.cellsAt, Abstract.paths] at member
        | some x =>
          rw [lookup] at member
          simp only [Option.getD_some] at member
          have knownX : ∀ entry ∈ x.paths, Origin.unknown ∉ entry.2 := by
            intro entry path
            rcases entry with ⟨p, cs⟩
            exact known (.field i :: p, cs) (record_path_mem xs i x p cs lookup path)
          obtain ⟨cs, path, inCs⟩ :=
            ih x member (record_component_firstOrder xs i x lookup firstOrder) knownX
          exact ⟨cs, record_path_mem xs i x rest cs lookup path, inCs⟩
      | element => simp [namesAt] at member
      | capture _ => simp [namesAt] at member
      | env => simp [namesAt] at member
    | list cs x ex =>
      have firstOrderX : hasFunction x = false := by simpa [hasFunction] using firstOrder
      have rootNotMem : Origin.unknown ∉ cs := known ([], cs) (by simp [Abstract.paths])
      have rootKnown : cs.contains .unknown = false := by
        simpa [List.contains_iff_mem] using rootNotMem
      have knownX : ∀ entry ∈ x.paths, Origin.unknown ∉ entry.2 := by
        intro entry path
        rcases entry with ⟨p, ds⟩
        exact known (.element :: p, ds) (list_path_mem cs x ex p ds path)
      cases step with
      | element =>
        simp only [namesAt, rootKnown, Bool.false_eq_true, if_false] at member
        obtain ⟨ds, path, inDs⟩ := ih x member firstOrderX knownX
        exact ⟨ds, list_path_mem cs x ex rest ds path, inDs⟩
      | field _ =>
        simp [namesAt] at member
        exact absurd member.1 rootNotMem
      | capture _ =>
        simp [namesAt] at member
        exact absurd member.1 rootNotMem
      | env =>
        simp [namesAt] at member
        exact absurd member.1 rootNotMem

/-- The cells-at fold never drops an origin of its accumulator. -/
theorem foldl_keeps (paths : List (Path × List Origin)) (acc : List Origin) {p : Path} {o : Origin}
    (member : o ∈ acc) :
    o ∈ paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) acc := by
  induction paths generalizing acc with
  | nil => exact member
  | cons entry paths ih =>
    rcases entry with ⟨q, xs⟩
    rw [List.foldl_cons]
    dsimp only
    apply ih
    by_cases same : (p == q) = true
    · rw [if_pos same]
      exact Ownership.FlatFragment.Description.mem_union acc xs o (Or.inl member)
    · rw [if_neg same]
      exact member

/-- A cell recorded at a path is among the cells at that path. -/
theorem cellsAt_of_mem_paths (a : Abstract) (p : Path) (cs : List Origin) (o : Origin)
    (path : (p, cs) ∈ a.paths) (member : o ∈ cs) : o ∈ a.cellsAt p := by
  unfold Abstract.cellsAt
  have general : ∀ (paths : List (Path × List Origin)) (acc : List Origin),
      (p, cs) ∈ paths → o ∈ paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) acc := by
    intro paths
    induction paths with
    | nil => intro _ h; simp at h
    | cons entry paths ih =>
      intro acc h
      rcases entry with ⟨q, xs⟩
      rw [List.foldl_cons]
      dsimp only
      rcases List.mem_cons.mp h with same | later
      · cases same
        rw [if_pos (beq_self_eq_true p)]
        exact foldl_keeps paths _ (Ownership.FlatFragment.Description.mem_union acc cs o (Or.inr member))
      · exact ih _ later
  exact general a.paths [] path

/-! ## The premise at a first-order call without captures -/

/-- An argument that holds an array at a path is in range. -/
theorem arg_in_range {hs : InPlaceSemantics.State} {args : List Value} {i : Nat} {q : Path} {c : Nat}
    (arrayAt : ArrayAt hs.heap (args[i]?.getD (.int 0)) q c) : i < args.length := by
  apply Classical.byContradiction
  intro notLt
  rw [List.getElem?_eq_none_iff.mpr (Nat.le_of_not_lt notLt)] at arrayAt
  simp only [Option.getD_none] at arrayAt
  unfold ArrayAt at arrayAt
  cases arrayAt

/-- The written-storage premise of the summary theorems holds at a
    first-order call without captures: from the call-site invariant and the
    call's own demands, no other input path holds an array linked to a
    written one. -/
theorem linkedWritesCovered_of_applyCall
    {vs : ValueSemantics.State} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract}
    {γ : Naming} {ctx : Context} {before after : St}
    (inv : Invariant vs hs env live aenv before.facts.escapes γ)
    (config : ctx.config = {})
    {s : Summary} {site : List Nat} {later : List Origin} {result : Abstract}
    {atoms : List Atom} {actuals : List Abstract} {args : List Value}
    (allVars : ∀ (k : Nat) (a : Atom), atoms[k]? = some a → ∃ x, a = Atom.var x)
    (actualOf : ∀ (k : Nat) (x : Var), atoms[k]? = some (Atom.var x) → ∃ a, aenv.lookup x = some a ∧ actuals[k]? = some a)
    (argOf : ∀ (k : Nat) (x : Var), atoms[k]? = some (Atom.var x) → ∃ o w, env.lookup x = some (o, w) ∧ args[k]? = some w)
    (liveOperands : ∀ (k : Nat) (x : Var), atoms[k]? = some (Atom.var x) → (x, []) ∈ live)
    (argsLength : args.length = atoms.length)
    (firstOrder : ∀ a ∈ actuals, hasFunction a = false)
    (known : ∀ a ∈ actuals, ∀ entry ∈ a.paths, Origin.unknown ∉ entry.2)
    (noClosures : ∀ w ∈ args, ∀ d caps, w ≠ .closure d caps)
    (rowsBase : ∀ w ∈ s.writes ++ s.consumes, w.base = w)
    (run : (applyCall ctx s site actuals [] later).run before = .ok (result, after))
    (ins : List Abstract) :
    LinkedWritesCovered s ins args args.length hs := by
  intro i q c _ arrayAtC permitted d connected j p _ arrayAtD
  -- Operand i.
  have iLt : i < args.length := arg_in_range arrayAtC
  have iBound : i < atoms.length := argsLength ▸ iLt
  obtain ⟨xI, atomI⟩ := allVars i atoms[i] (List.getElem?_eq_getElem iBound)
  have lookupI : atoms[i]? = some (Atom.var xI) := by rw [List.getElem?_eq_getElem iBound, atomI]
  obtain ⟨absI, aenvI, actualI⟩ := actualOf i xI lookupI
  obtain ⟨oI, wI, envI, argI⟩ := argOf i xI lookupI
  have liveI := liveOperands i xI lookupI
  rw [argI] at arrayAtC
  simp only [Option.getD_some] at arrayAtC
  have coversI : Covers γ hs.heap absI wI :=
    (inv.described xI [] liveI oI wI absI wI envI aenvI rfl).1.1
  -- Operand j.
  have jLt : j < args.length := arg_in_range arrayAtD
  have jBound : j < atoms.length := argsLength ▸ jLt
  obtain ⟨xJ, atomJ⟩ := allVars j atoms[j] (List.getElem?_eq_getElem jBound)
  have lookupJ : atoms[j]? = some (Atom.var xJ) := by rw [List.getElem?_eq_getElem jBound, atomJ]
  obtain ⟨absJ, aenvJ, actualJ⟩ := actualOf j xJ lookupJ
  obtain ⟨oJ, wJ, envJ, argJ⟩ := argOf j xJ lookupJ
  have liveJ := liveOperands j xJ lookupJ
  rw [argJ] at arrayAtD
  simp only [Option.getD_some] at arrayAtD
  have coversJ : Covers γ hs.heap absJ wJ :=
    (inv.described xJ [] liveJ oJ wJ absJ wJ envJ aenvJ rfl).1.1
  -- The written path is not an environment path: the argument is no closure.
  have notEnv : ∀ rest, q ≠ .env :: rest := by
    intro rest same
    subst same
    unfold ArrayAt at arrayAtC
    cases arrayAtC with
    | @env d caps _ _ _ _ =>
      exact noClosures (.closure d caps) (List.mem_of_getElem? argI) d caps rfl
  -- The same path is permitted by assumption.
  by_cases same : (j, p) = (i, q)
  · simp only [Prod.mk.injEq] at same
    obtain ⟨rfl, rfl⟩ := same
    exact permitted
  -- The row the premise names is a parameter row the call demanded.
  rcases permitted with row | envCase
  · obtain ⟨w, wMember, wBase⟩ := List.any_eq_true.mp row
    have base : w.base = inputOrigin args.length i q := eq_of_beq wBase
    rw [rowsBase w wMember] at base
    have param : inputOrigin args.length i q = .parameter i q := by
      unfold inputOrigin
      rw [if_pos iLt]
    rw [param] at base
    subst base
    have problem := applyCall_demands config run _ wMember
    rw [instantiateOrigin_parameter site actuals [] i q notEnv, actualI] at problem
    simp only [Option.getD_some] at problem
    have disjoint := (demandProblem_sound γ inv.separating ({} : Config) before.facts.escapes _ _ _ problem).2.2
      default_no_disjoint
    -- The written array is named by the row's cells.
    obtain ⟨o, oMember, cIn⟩ := coversI q c arrayAtC
    obtain ⟨cs, pathQ, oInCs⟩ := namesAt_mem_paths_exact q absI o oMember
      (firstOrder absI (List.mem_of_getElem? actualI)) (known absI (List.mem_of_getElem? actualI))
    have oInCells : o ∈ absI.cellsAt q := cellsAt_of_mem_paths absI q cs o pathQ oInCs
    -- The linked array shares its origins, and another operand path names it.
    have guarded : Protected hs env live d :=
      Or.inl ⟨xJ, [], oJ, wJ, wJ, liveJ, envJ, rfl, atPath_reaches arrayAtD⟩
    have dIn : d ∈ γ o := (inv.linkNamed c d connected guarded o).mp cIn
    obtain ⟨o', o'Member, dIn'⟩ := coversJ p d arrayAtD
    obtain ⟨cs', pathP, o'InCs'⟩ := namesAt_mem_paths_exact p absJ o' o'Member
      (firstOrder absJ (List.mem_of_getElem? actualJ)) (known absJ (List.mem_of_getElem? actualJ))
    have o'InOthers : o' ∈ otherPaths actuals [] (.parameter i q) :=
      mem_otherPaths actuals [] i j q p absJ cs' o' notEnv actualJ pathP o'InCs' same
    exact absurd ⟨o', o'InOthers, dIn'⟩ (disjoint d ⟨o, oInCells, dIn⟩)
  · simp only [Bool.and_eq_true, beq_iff_eq] at envCase
    obtain ⟨rfl, _⟩ := envCase
    exact absurd rfl (notEnv [])

end Ownership.CallDerivation
