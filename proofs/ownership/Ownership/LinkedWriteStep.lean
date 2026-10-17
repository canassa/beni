-- Last link of the proof import chain: this module imports `CallDerivation`
-- and sees every earlier realization of an equation lemma (#182). The root
-- imports it last.
import Ownership.CallDerivation

/-! The naming clause of the invariant survives a successful, demand-guarded
linked write with the same naming (#169). An array protected after the
write was protected before it: a path in the new heap either exists in the
old heap or first meets the written component, which no permanent observer
reaches (the Unescaped test with `keptEscaped`, carried along the component
by `linkNamed`) and no continuation-live holder reaches (the Dead test with
`Covers` and the live cells). The second half connects the demand's `later`
to the checker's `liveCells`: every name at a path below a live use's field
path is a live cell, for records, lists, closures and symbolic inputs. The
proof needs no contents of the written component. `LinksValid` under
`writeLinked` is not proved here: it needs the contents after the splice. -/

namespace Ownership.LinkedWriteStep

open InPlaceSemantics HeapProof Soundness LinkedWriteFrame Ownership.FlatFragment.Support
  Ownership.FlatFragment.NamingFacts Ownership.CallDerivation

/-- A path in a heap that agrees with another outside a set of arrays either
    exists in the other heap or first meets an array of the set. -/
theorem reaches_decompose {heap heap' : Heap} {inside : Nat → Prop}
    (agree : ∀ a, ¬ inside a → heap'[a]? = heap[a]?) {v w : Value}
    (reaches : Reaches heap' v w) :
    Reaches heap v w ∨ ∃ a, inside a ∧ Reaches heap v (.ref a) := by
  induction reaches with
  | refl v => exact Or.inl (Reaches.refl v)
  | @element c xs x w lookup mem _ ih =>
    by_cases member : inside c
    · exact Or.inr ⟨c, member, Reaches.refl _⟩
    · rw [agree c member] at lookup
      rcases ih with direct | ⟨a, aIn, toA⟩
      · exact Or.inl (Reaches.element lookup mem direct)
      · exact Or.inr ⟨a, aIn, Reaches.element lookup mem toA⟩
  | @field xs x w mem _ ih =>
    rcases ih with direct | ⟨a, aIn, toA⟩
    · exact Or.inl (Reaches.field mem direct)
    · exact Or.inr ⟨a, aIn, Reaches.field mem toA⟩
  | @capture d caps x w mem _ ih =>
    rcases ih with direct | ⟨a, aIn, toA⟩
    · exact Or.inl (Reaches.capture mem direct)
    · exact Or.inr ⟨a, aIn, Reaches.capture mem toA⟩

/-- A reached value is at some path. -/
theorem reaches_atPath {heap : Heap} {v w : Value} (reaches : Reaches heap v w) :
    ∃ q, AtPath heap v q w := by
  induction reaches with
  | refl v => exact ⟨[], AtPath.here v⟩
  | @element c xs x w lookup mem _ ih =>
    obtain ⟨q, path⟩ := ih
    exact ⟨.element :: q, AtPath.element lookup mem path⟩
  | @field xs x w mem _ ih =>
    obtain ⟨q, path⟩ := ih
    obtain ⟨i, lookup⟩ := List.mem_iff_getElem?.mp mem
    exact ⟨.field i :: q, AtPath.field lookup path⟩
  | @capture d caps x w mem _ ih =>
    obtain ⟨q, path⟩ := ih
    obtain ⟨i, lookup⟩ := List.mem_iff_getElem?.mp mem
    exact ⟨.capture i :: q, AtPath.capture lookup path⟩

/-- After a demand-guarded linked write of a live receiver's array, the
    naming clause holds for the continuation's uses with the same naming:
    an array protected after the write was protected before it, because a
    new path to it would have to pass through the written component, which
    no observer and no continuation-live holder reaches before the write. -/
theorem linkNamed_after_writeLinked
    {vs : ValueSemantics.State} {hs hs' : State} {env : List (Var × Observation × Value)}
    {live after : Live} {aenv : Env Abstract} {γ : Naming} {before afterSt : St}
    (inv : Invariant vs hs env live aenv before.facts.escapes γ)
    (liveAfter : ∀ u ∈ after, u ∈ live)
    {x : Var} {ox : Observation} {c : Nat} (receiverLive : (x, []) ∈ live)
    (envX : env.lookup x = some (ox, .ref c))
    {cs later others : List Origin} (receiverNamed : named γ cs c)
    {u : Unit} (demandRun : (demand ({} : Config) cs later others).run before = .ok (u, afterSt))
    (laterCovers : ∀ (y : Var) (p : Path) (o : Observation) (w : Value) (a : Abstract) (w' : Value)
      (q : Path) (cell : Origin), (y, p) ∈ after → env.lookup y = some (o, w) →
      aenv.lookup y = some a → projectVal w p = some w' → cell ∈ namesAt (a.atPath p) q →
      cell ∈ later)
    (covered : ∀ (y : Var) (p : Path), (y, p) ∈ after → ∀ (o : Observation) (w : Value),
      env.lookup y = some (o, w) → (aenv.lookup y).isSome = true)
    {xs : List Value} {r : Value} (run : (writeLinked c xs).run hs = .ok (r, hs')) :
    LinkNamed hs' env after γ := by
  have frame := writeLinked_preserves run
  have receiverProtected : Protected hs env live c :=
    Or.inl ⟨x, [], ox, .ref c, .ref c, receiverLive, envX, rfl, Reaches.refl _⟩
  have componentNamed : ∀ a, LinkConnected hs.links c a → named γ cs a := by
    intro a connected
    obtain ⟨o, oMember, cIn⟩ := receiverNamed
    exact ⟨o, oMember, (inv.linkNamed a c (LinkConnected.symm connected) receiverProtected o).mpr cIn⟩
  have keptApart : ∀ k ∈ hs.kept.toList, ∀ a, LinkConnected hs.links c a →
      ¬ Reaches hs.heap k (.ref a) := by
    intro k member a connected reaches
    exact demand_success_no_kept_reaches inv demandRun (componentNamed a connected) member reaches
  have liveApart : ∀ (y : Var) (p : Path) (o : Observation) (w w' : Value), (y, p) ∈ after →
      env.lookup y = some (o, w) → projectVal w p = some w' →
      ∀ a, LinkConnected hs.links c a → ¬ Reaches hs.heap w' (.ref a) := by
    intro y p o w w' member envY proj a connected reaches
    obtain ⟨ay, aenvY⟩ := Option.isSome_iff_exists.mp (covered y p member o w envY)
    have covers : Covers γ hs.heap (ay.atPath p) w' :=
      (inv.described y p (liveAfter _ member) o w ay w' envY aenvY proj).1.1
    obtain ⟨q, path⟩ := reaches_atPath reaches
    obtain ⟨cell, cellMember, aIn⟩ := covers q a path
    have inLater : cell ∈ later := laterCovers y p o w ay w' q cell member envY aenvY proj cellMember
    exact demand_success_live_separate inv.separating demandRun a (componentNamed a connected)
      ⟨cell, inLater, aIn⟩
  have protectedBefore : ∀ d, Protected hs' env after d → Protected hs env live d := by
    intro d guarded
    have agree : ∀ a, ¬ LinkConnected hs.links c a → hs'.heap[a]? = hs.heap[a]? :=
      fun a outside => frame.heap a outside
    rcases guarded with ⟨y, p, o, w, w', member, envY, proj, reaches⟩ | ⟨k, member, reaches⟩
    · rcases reaches_decompose agree reaches with direct | ⟨a, connected, toA⟩
      · exact Or.inl ⟨y, p, o, w, w', liveAfter _ member, envY, proj, direct⟩
      · exact absurd toA (liveApart y p o w w' member envY proj a connected)
    · rw [frame.kept] at member
      rcases reaches_decompose agree reaches with direct | ⟨a, connected, toA⟩
      · exact Or.inr ⟨k, member, direct⟩
      · exact absurd toA (keptApart k member a connected)
  intro c' d connected guarded o
  rw [frame.links_eq] at connected
  exact inv.linkNamed c' d connected (protectedBefore d guarded) o

/-! ## Names below a live use's path are live cells -/

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- A live use's path projects through record fields only. -/
theorem projectVal_fieldPath {w w' : Value} {p : Path} (proj : projectVal w p = some w') :
    ∀ s ∈ p, ∃ i, s = Step.field i := by
  induction p generalizing w with
  | nil => intro s member; simp at member
  | cons step rest ih =>
    intro s member
    cases w with
    | record xs =>
      cases step with
      | field i =>
        simp only [projectVal] at proj
        rcases List.mem_cons.mp member with rfl | later
        · exact ⟨i, rfl⟩
        · cases lookup : xs[i]? with
          | none =>
            simp only [lookup] at proj
            cases proj
          | some x =>
            simp only [lookup] at proj
            exact ih proj s later
      | element => simp [projectVal] at proj
      | capture _ => simp [projectVal] at proj
      | env => simp [projectVal] at proj
    | int _ => simp [projectVal] at proj
    | ref _ => simp [projectVal] at proj
    | closure _ _ => simp [projectVal] at proj

theorem isPrefix_append (p r : Path) : isPrefix p (p ++ r) = true := by
  unfold isPrefix
  rw [List.take_left]
  exact beq_self_eq_true p

/-- The paths of the abstract at a field path are the abstract's paths below it. -/
theorem atPath_paths_shift (p : Path) (fieldPath : ∀ s ∈ p, ∃ i, s = Step.field i) (a : Abstract)
    (r : Path) (cs : List Origin) (member : (r, cs) ∈ (a.atPath p).paths) :
    (p ++ r, cs) ∈ a.paths := by
  induction p generalizing a with
  | nil => simpa [Abstract.atPath] using member
  | cons step rest ih =>
    obtain ⟨i, rfl⟩ := fieldPath step (by simp)
    have fieldRest : ∀ s ∈ rest, ∃ i, s = Step.field i := fun s h => fieldPath s (List.mem_cons_of_mem _ h)
    cases a with
    | record xs =>
      simp only [Abstract.atPath] at member
      cases lookup : xs[i]? with
      | none =>
        rw [lookup] at member
        simp only [Option.getD_none] at member
        cases rest <;> simp [Abstract.atPath, Abstract.paths] at member
      | some x =>
        rw [lookup] at member
        simp only [Option.getD_some] at member
        exact record_path_mem xs i x (rest ++ r) cs lookup (ih fieldRest x member)
    | bottom => simp [Abstract.atPath, Abstract.paths] at member
    | scalar => simp [Abstract.atPath, Abstract.paths] at member
    | list _ _ _ => simp [Abstract.atPath, Abstract.paths] at member
    | function _ _ => simp [Abstract.atPath, Abstract.paths] at member
    | symbolic _ _ _ _ => simp [Abstract.atPath, Abstract.paths] at member

/-- A member of the alternatives' name fold is in the start or in one alternative. -/
theorem mem_alts_fold (alts : List (Nat × List Abstract)) (i : Nat) (rest : Path)
    (init : List Origin) (cell : Origin)
    (member : cell ∈ alts.foldl (fun cs (_, caps) => union cs (namesAt (caps[i]?.getD .bottom) rest)) init) :
    cell ∈ init ∨ ∃ alt ∈ alts, cell ∈ namesAt (alt.2[i]?.getD .bottom) rest := by
  induction alts generalizing init with
  | nil => exact Or.inl member
  | cons alt alts ih =>
    rcases alt with ⟨id, caps⟩
    rw [List.foldl_cons] at member
    dsimp only at member
    rcases ih _ member with inAcc | ⟨alt', altMember, inAlt⟩
    · rcases mem_union_cases init _ cell inAcc with old | new
      · exact Or.inl old
      · exact Or.inr ⟨(id, caps), by simp, new⟩
    · exact Or.inr ⟨alt', List.mem_cons_of_mem _ altMember, inAlt⟩

theorem mem_cells_fold (xs : List Abstract) (init : List Origin) (cell : Origin)
    (member : cell ∈ xs.foldl (fun ds x => union ds x.cells) init) :
    cell ∈ init ∨ ∃ x ∈ xs, cell ∈ x.cells := by
  induction xs generalizing init with
  | nil => exact Or.inl member
  | cons x xs ih =>
    rw [List.foldl_cons] at member
    rcases ih _ member with inAcc | ⟨y, yMember, inY⟩
    · rcases mem_union_cases init x.cells cell inAcc with old | new
      · exact Or.inl old
      · exact Or.inr ⟨x, by simp, new⟩
    · exact Or.inr ⟨y, List.mem_cons_of_mem _ yMember, inY⟩

theorem mem_envCells_fold (alts : List (Nat × List Abstract)) (init : List Origin) (cell : Origin)
    (member : cell ∈ alts.foldl (fun cs (_, xs) => xs.foldl (fun ds x => union ds x.cells) cs) init) :
    cell ∈ init ∨ ∃ alt ∈ alts, ∃ x ∈ alt.2, cell ∈ x.cells := by
  induction alts generalizing init with
  | nil => exact Or.inl member
  | cons alt alts ih =>
    rcases alt with ⟨id, xs⟩
    rw [List.foldl_cons] at member
    dsimp only at member
    rcases ih _ member with inAcc | ⟨alt', altMember, x, xMember, inX⟩
    · rcases mem_cells_fold xs init cell inAcc with old | ⟨x, xMember, inX⟩
      · exact Or.inl old
      · exact Or.inr ⟨(id, xs), by simp, x, xMember, inX⟩
    · exact Or.inr ⟨alt', List.mem_cons_of_mem _ altMember, x, xMember, inX⟩

/-- A cell of an abstract is recorded at one of its paths. -/
theorem mem_cells (a : Abstract) (cell : Origin) (member : cell ∈ a.cells) :
    ∃ r cs, (r, cs) ∈ a.paths ∧ cell ∈ cs := by
  unfold Abstract.cells at member
  have general : ∀ (paths : List (Path × List Origin)) (init : List Origin),
      cell ∈ paths.foldl (fun cs (_, xs) => union cs xs) init →
      cell ∈ init ∨ ∃ r cs, (r, cs) ∈ paths ∧ cell ∈ cs := by
    intro paths
    induction paths with
    | nil => intro init h; exact Or.inl h
    | cons entry paths ih =>
      intro init h
      rcases entry with ⟨r, xs⟩
      rw [List.foldl_cons] at h
      dsimp only at h
      rcases ih _ h with inAcc | ⟨r', cs', path, inCs⟩
      · rcases mem_union_cases init xs cell inAcc with old | new
        · exact Or.inl old
        · exact Or.inr ⟨r, xs, by simp, new⟩
      · exact Or.inr ⟨r', cs', List.mem_cons_of_mem _ path, inCs⟩
  rcases general a.paths [] member with none | found
  · simp at none
  · exact found

/-- A capture path of an alternative's capture abstract is a path of the function abstract. -/
theorem function_path_mem (cs : List Origin) (alts : List (Nat × List Abstract))
    (alt : Nat × List Abstract) (altMember : alt ∈ alts) (i : Nat) (x : Abstract)
    (lookup : alt.2[i]? = some x) (r : Path) (ds : List Origin) (path : (r, ds) ∈ x.paths) :
    (.capture i :: r, ds) ∈ (Abstract.function cs alts).paths := by
  simp only [Abstract.paths]
  refine List.mem_cons_of_mem _ (List.mem_flatMap.mpr ⟨⟨alt, altMember⟩, List.mem_attach _ _, ?_⟩)
  refine List.mem_flatMap.mpr ⟨(⟨x, List.mem_of_getElem? lookup⟩, i), ?_,
    List.mem_map.mpr ⟨(r, ds), path, rfl⟩⟩
  rw [List.mk_mem_zipIdx_iff_getElem?]
  simp [lookup]

/-- The names at any path of any abstract are drawn from its recorded paths. -/
theorem namesAt_mem_paths_general (q : Path) (b : Abstract) (cell : Origin)
    (member : cell ∈ namesAt b q) : ∃ r cs, (r, cs) ∈ b.paths ∧ cell ∈ cs := by
  induction q generalizing b with
  | nil =>
    obtain ⟨cs, path, inCs⟩ := mem_cellsAt b [] cell member
    exact ⟨[], cs, path, inCs⟩
  | cons step rest ih =>
    cases b with
    | bottom => simp [namesAt] at member
    | scalar => simp [namesAt] at member
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
          obtain ⟨r, cs, path, inCs⟩ := ih x member
          exact ⟨.field i :: r, cs, record_path_mem xs i x r cs lookup path, inCs⟩
      | element => simp [namesAt] at member
      | capture _ => simp [namesAt] at member
      | env => simp [namesAt] at member
    | list cs x ex =>
      cases step with
      | element =>
        simp only [namesAt] at member
        by_cases unknown : cs.contains .unknown = true
        · rw [if_pos unknown] at member
          exact ⟨[], cs, by simp [Abstract.paths], member⟩
        · rw [if_neg unknown] at member
          obtain ⟨r, ds, path, inDs⟩ := ih x member
          exact ⟨.element :: r, ds, list_path_mem cs x ex r ds path, inDs⟩
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
    | function cs alts =>
      cases step with
      | capture i =>
        simp only [namesAt] at member
        rcases mem_alts_fold alts i rest [] cell member with none | ⟨alt, altMember, inAlt⟩
        · simp at none
        · cases lookup : alt.2[i]? with
          | none =>
            rw [lookup] at inAlt
            simp only [Option.getD_none] at inAlt
            cases rest <;> simp [namesAt, Abstract.cellsAt, Abstract.paths] at inAlt
          | some x =>
            rw [lookup] at inAlt
            simp only [Option.getD_some] at inAlt
            obtain ⟨r, ds, path, inDs⟩ := ih x inAlt
            exact ⟨.capture i :: r, ds, function_path_mem cs alts alt altMember i x lookup r ds path, inDs⟩
      | env =>
        cases rest with
        | nil =>
          simp only [namesAt, Abstract.envCells] at member
          rcases mem_envCells_fold alts [] cell member with none | ⟨alt, altMember, x, xMember, inX⟩
          · simp at none
          · obtain ⟨r, ds, path, inDs⟩ := mem_cells x cell inX
            obtain ⟨i, lookup⟩ := List.mem_iff_getElem?.mp xMember
            exact ⟨.capture i :: r, ds, function_path_mem cs alts alt altMember i x lookup r ds path, inDs⟩
        | cons _ _ => simp [namesAt] at member
      | field _ => simp [namesAt] at member
      | element => simp [namesAt] at member
    | symbolic j t cs es =>
      cases step with
      | capture _ =>
        simp only [namesAt] at member
        exact ⟨[.env], es, by simp [Abstract.paths], member⟩
      | env =>
        simp only [namesAt] at member
        exact ⟨[.env], es, by simp [Abstract.paths], member⟩
      | field _ => simp [namesAt] at member
      | element => simp [namesAt] at member

/-- Every name at a path below a live use's field path is a live cell. -/
theorem namesAt_atPath_in_liveCells (env : Env Abstract) (l : Live) (y : Var) (p : Path)
    (a : Abstract) (use : (y, p) ∈ l) (found : env.lookup y = some a)
    (fieldPath : ∀ s ∈ p, ∃ i, s = Step.field i) (q : Path) (cell : Origin)
    (member : cell ∈ namesAt (a.atPath p) q) : cell ∈ liveCells env l := by
  obtain ⟨r, cs, path, inCs⟩ := namesAt_mem_paths_general q (a.atPath p) cell member
  have shifted := atPath_paths_shift p fieldPath a r cs path
  rw [Ownership.FlatFragment.LiveCells.liveCells_eq_fold]
  apply Ownership.FlatFragment.LiveCells.foldl_member _
    (Ownership.FlatFragment.LiveCells.useStep_mono env) l [] (y, p) use cell
  intro acc
  unfold Ownership.FlatFragment.LiveCells.useStep
  simp only [found]
  apply Ownership.FlatFragment.LiveCells.foldl_member _
    (Ownership.FlatFragment.LiveCells.pathStep_mono p) a.paths acc (p ++ r, cs) shifted cell
  intro acc'
  unfold Ownership.FlatFragment.LiveCells.pathStep
  simp only [isPrefix_append, Bool.true_or, ite_true]
  exact Ownership.FlatFragment.Description.mem_union acc' cs cell (Or.inr inCs)

/-- The naming clause after a demand-guarded linked write, with the checker's
    own live cells: `later` holds every live cell of the continuation. -/
theorem linkNamed_after_writeLinked_liveCells
    {vs : ValueSemantics.State} {hs hs' : State} {env : List (Var × Observation × Value)}
    {live after : Live} {aenv : Env Abstract} {γ : Naming} {before afterSt : St}
    (inv : Invariant vs hs env live aenv before.facts.escapes γ)
    (liveAfter : ∀ u ∈ after, u ∈ live)
    {x : Var} {ox : Observation} {c : Nat} (receiverLive : (x, []) ∈ live)
    (envX : env.lookup x = some (ox, .ref c))
    {cs later others : List Origin} (receiverNamed : named γ cs c)
    {u : Unit} (demandRun : (demand ({} : Config) cs later others).run before = .ok (u, afterSt))
    (laterIncludes : ∀ cell ∈ liveCells aenv after, cell ∈ later)
    (covered : ∀ (y : Var) (p : Path), (y, p) ∈ after → ∀ (o : Observation) (w : Value),
      env.lookup y = some (o, w) → (aenv.lookup y).isSome = true)
    {xs : List Value} {r : Value} (run : (writeLinked c xs).run hs = .ok (r, hs')) :
    LinkNamed hs' env after γ := by
  refine linkNamed_after_writeLinked inv liveAfter receiverLive envX receiverNamed demandRun ?_ covered run
  intro y p o w a w' q cell member envY aenvY proj cellMember
  exact laterIncludes cell
    (namesAt_atPath_in_liveCells aenv after y p a member aenvY (projectVal_fieldPath proj) q cell cellMember)

end Ownership.LinkedWriteStep
