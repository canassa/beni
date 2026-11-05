import Ownership.LinkedWriteRun

/-! The fragment modules form one import chain. Its first link imports
`LinkedWriteRun`, after `LinkedWriteValid` and `LinkClauses`; `LinkClauses`
imports every other proof and executable module of the package. The audit rejects an equation lemma that two modules realize, so a
module that unfolds a model definition must see every earlier realization. -/

/-! The first flat fragment: the predicate, demand and footprint support, the naming extension, flat descriptions, root names, live sets, live cells, and liveness bookkeeping. -/

/-! support for a separate flat ANF trace theorem.
No theorem below uses a pinned soundness obligation.
The demand lemmas take successful executions of the actual default checker
operation. They do not replace its test with an external permission oracle. -/

namespace Ownership.FlatFragment.State

/-- A type that holds no dictionary at any position. The predicate reads the
    type only. `Ty.fn` names no capture types, so `fn` says nothing about the
    captures of a closure, which can hold a dictionary. The flat fragment
    admits no function value (`FlatType` has no `fn` case, `FlatAbstract` no
    function abstract), so no lemma here meets that case. A fragment that
    admits closures must read their captures through their declarations'
    types (`captureTypes`) first. The fragment does not ask it of a type
    (#1840); a representation holds no dictionary (`dictFree_entryType`), and
    a case with no dictionary in its result type converts its result with it
    (`success_of_dictFree`). -/
inductive DictFree : Ty → Prop where
  | int : DictFree .int
  | list (t : Ty) : DictFree t → DictFree (.list t)
  | chain (t : Ty) : DictFree t → DictFree (.chain t)
  | builder (t : Ty) : DictFree t → DictFree (.builder t)
  | record (ts : List Ty) : (∀ t ∈ ts, DictFree t) → DictFree (.record ts)
  | result (error success : Ty) : DictFree error → DictFree success →
      DictFree (.result error success)
  | fn (parameters : List Ty) (result : Ty) : DictFree (.fn parameters result)
  | object (ts : List Ty) : (∀ t ∈ ts, DictFree t) → DictFree (.object ts)

/-- The types of the flat fragment: integers, lists of flat types, integer
chains, records, results, dictionaries of flat types (#522) and record
objects of flat fields (#316). A list can hold results, chains and
dictionaries; a dictionary's value can be a dictionary (#1840). -/
inductive FlatType : Ty → Prop where
  | int : FlatType .int
  | list (t : Ty) : FlatType t → FlatType (.list t)
  | chainInt : FlatType (.chain .int)
  | record (ts : List Ty) : (∀ t ∈ ts, FlatType t) → FlatType (.record ts)
  | result (error success : Ty) : FlatType error → FlatType success →
      FlatType (.result error success)
  | dict (t : Ty) : FlatType t → FlatType (.dict t)
  | object (ts : List Ty) : (∀ t ∈ ts, FlatType t) → FlatType (.object ts)

mutual
/-- The type of a value's concrete representation: a dictionary of `t` is a
    list of entry records `[Int, t]` (#1796). Every other type keeps its
    shape. -/
def entryType : Ty → Ty
  | .dict t => .list (.record [.int, entryType t])
  | .list t => .list (entryType t)
  | .chain t => .chain (entryType t)
  | .builder t => .builder (entryType t)
  | .record ts => .record (entryTypes ts)
  | .result e a => .result (entryType e) (entryType a)
  | .int => .int
  | .fn ps r => .fn ps r
  | .object ts => .object (entryTypes ts)
def entryTypes : List Ty → List Ty
  | [] => []
  | t :: ts => entryType t :: entryTypes ts
end

end Ownership.FlatFragment.State

namespace Ownership.FlatFragment.Fields

/-- The type at a field path: the type of a projection through record
fields. -/
def fieldTyAt : Ty → Path → Option Ty
  | t, [] => some t
  | .record ts, .field i :: rest => match ts[i]? with
    | some t => fieldTyAt t rest
    | none => none
  | _, _ => none

/-- The type at a use path: record fields, then at most one record object's
slot and the record's fields. A field read of an object uses the object's
element and then the field (`fieldUses`, #316), and its operand is an atom,
whose path has record fields only; so a live use never enters a second
object. -/
def tyAt : Ty → Path → Option Ty
  | t, [] => some t
  | .record ts, .field i :: rest => match ts[i]? with
    | some t => tyAt t rest
    | none => none
  | .object ts, .element :: rest => fieldTyAt (.record ts) rest
  | _, _ => none

/-- A field path's type is its use path's type. -/
theorem tyAt_of_fieldTyAt {ty t : Ty} {p : Path} (typed : fieldTyAt ty p = some t) :
    tyAt ty p = some t := by
  induction p generalizing ty with
  | nil => simpa [fieldTyAt, tyAt] using typed
  | cons step rest ih =>
    cases step <;> cases ty <;> simp [fieldTyAt] at typed
    rename_i i ts
    cases lookup : ts[i]? with
    | none => simp [lookup] at typed
    | some t' =>
      simp only [lookup] at typed
      simp only [tyAt, lookup]
      exact ih typed

/-- `tyAt` and `fieldType` agree where `tyAt` has a type. -/
theorem fieldType_of_tyAt {ty t : Ty} {p : Path} (typed : tyAt ty p = some t) :
    Soundness.fieldType ty p = t := by
  induction p generalizing ty with
  | nil =>
    rw [Soundness.fieldType_nil]
    simpa [tyAt] using typed
  | cons step rest ih =>
    cases step <;> cases ty <;> simp [tyAt] at typed
    · rename_i i ts
      cases lookup : ts[i]? with
      | none => simp [lookup] at typed
      | some t' =>
        simp only [lookup] at typed
        show Soundness.fieldType (ts[i]?.getD .int) rest = t
        rw [lookup]
        exact ih typed
    · rename_i ts
      show Soundness.fieldType (.record ts) rest = t
      exact ih (tyAt_of_fieldTyAt typed)

end Ownership.FlatFragment.Fields

namespace Ownership.FlatFragment.Support

open InPlaceSemantics HeapProof Soundness

/-- The integer primitives of the fragment: two atoms, which typing fixes to
`Int`, an integer result, no heap effect and no recorded read. -/
inductive ScalarOp : Prim → Prop where
  | add : ScalarOp .add
  | sub : ScalarOp .sub
  | eq : ScalarOp .eq
  | lt : ScalarOp .lt

/-- The integer both interpreters compute for an integer primitive. -/
def scalarResult : Prim → Int → Int → Int
  | .add, x, y => x + y
  | .sub, x, y => x - y
  | .eq, x, y => if x == y then 1 else 0
  | .lt, x, y => if x < y then 1 else 0
  | _, _, _ => 0

/-- The checker returns a scalar for an integer primitive and changes nothing. -/
theorem primitive_scalar_run {op : Prim} (sop : ScalarOp op) (ctx : Context) (site : List Nat)
    (x y : Abstract) (later : List Origin) (before : St) :
    (primitive ctx site op [x, y] later).run before = .ok (.scalar, before) := by
  cases sop <;> (unfold primitive; rfl)

/-- The expression fragment. Operands are atoms. Typing fixes the scalar
operands, indexes, branch conditions and chain heads to integers. Lists hold
any flat type, including records, results, chains, dictionaries and further
lists. A literal
names its flat element type. List reads, writes and copies use that type.
Records and field projections preserve the type structure. Result constructors
name a flat type for the unused slot; a result case binds the active payload.
Integer chains support construction and a case that binds the head and tail.
Record objects (#316) support a literal, a field read, `Record.copy` and an
update written in place; typing fixes a field read and an update to a record
object, and an update's values to its fields' types.
Dictionaries (#522) support the empty dictionary, an insert, a remove, a
lookup and the size; typing fixes their keys to integers, and a value can be
any flat type, a dictionary too (#1840). A dictionary focus
is outside the fragment: the checker summarises its body as a scope.
Each branch or case arm is itself a fragment expression. -/
inductive FlatANF0 : Expr → Prop where
  | atom : FlatANF0 (.atom a)
  | letE : FlatANF0 rhs → FlatANF0 rest → FlatANF0 (.letE v rhs rest)
  | literal (t : Ty) : Ownership.FlatFragment.State.FlatType t → FlatANF0 (.prim (.literal t) args)
  | push : FlatANF0 (.prim .push [receiver, item])
  | length : FlatANF0 (.prim .length [receiver])
  | shared : FlatANF0 (.prim .shared [value])
  | scalar : ScalarOp op → FlatANF0 (.prim op [a, b])
  | record : FlatANF0 (.prim .record args)
  | branch : FlatANF0 yes → FlatANF0 no → FlatANF0 (.branch c yes no)
  | ok : Ownership.FlatFragment.State.FlatType error → FlatANF0 (.prim (.ok error) [x])
  | err : Ownership.FlatFragment.State.FlatType success → FlatANF0 (.prim (.err success) [x])
  | resultCase : FlatANF0 onError → FlatANF0 onSuccess →
      FlatANF0 (.resultCase input err ok onError onSuccess)
  | endChain : FlatANF0 (.prim (.endChain .int) [])
  | link : FlatANF0 (.prim .link [head, tail])
  | chainCase : FlatANF0 onEnd → FlatANF0 onLink →
      FlatANF0 (.chainCase input head tail onEnd onLink)
  | atRead : FlatANF0 (.prim .at [receiver, index, fallback])
  | set : FlatANF0 (.prim .set [receiver, index, item])
  | copy : FlatANF0 (.prim .copy [receiver])
  | prepend : FlatANF0 (.prim .prepend [item, receiver])
  | dictEmpty (t : Ty) : Ownership.FlatFragment.State.FlatType t → FlatANF0 (.prim (.dictEmpty t) [])
  | dictInsert : FlatANF0 (.prim .dictInsert [receiver, key, item])
  | dictRemove : FlatANF0 (.prim .dictRemove [receiver, key])
  | dictGet : FlatANF0 (.prim .dictGet [receiver, key])
  | dictSize : FlatANF0 (.prim .dictSize [receiver])
  | view (front : Bool) : FlatANF0 (.prim (.view front) [receiver])
  /-- The record objects (#316): a record literal, a field read, `Record.copy`
  and an update written in place. -/
  | object : FlatANF0 (.prim .object args)
  | get (index : Nat) : FlatANF0 (.prim (.get index) [receiver])
  | recordCopy : FlatANF0 (.prim .recordCopy [receiver])
  | assign : FlatANF0 (.assign width fields base values)

theorem lookup_option_of_success {α : Type} [Inhabited α] {env : Env α} {key : Var} {value : α}
    (run : lookup env key = .ok value) :
    env.lookup key = some value := by
  cases found : env.lookup key with
  | none => simp [lookup, found] at run
  | some actual =>
    have equal : actual = value := by simpa [lookup, found] using run
    exact congrArg some equal

/-- The existing demand soundness theorem states the live and operand frame
conditions. This lemma also retains the recorded-escape branch. -/
theorem demandProblem_none_not_escaped
    (passed : demandProblem cfg escapes cs later others = none) :
    ∀ origin ∈ cs, ¬ Escaped escapes origin := by
  unfold demandProblem at passed
  split at passed
  · contradiction
  split at passed
  · contradiction
  split at passed
  · contradiction
  rename_i knownPass unescapedPass escapePass
  have allUnescaped : cs.all unescaped = true := by simpa using unescapedPass
  have noEscapes : cellOverlap (cs.map Origin.base) (escapes.map Origin.base) = false := by
    simpa using escapePass
  intro origin member escaped
  have allowed := List.all_eq_true.mp allUnescaped origin member
  rcases escaped with shared | recorded
  · rw [allowed] at shared
    contradiction
  · have originMember : origin.base ∈ cs.map Origin.base :=
      List.mem_map.mpr ⟨origin, member, rfl⟩
    have absent := List.any_eq_false.mp noEscapes origin.base originMember
    apply absent
    simpa [cellOverlap] using recorded

/-- Extract the actual permission test from a successful default demand. -/
theorem demand_success_problem
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after)) :
    demandProblem ({} : Config) before.facts.escapes cs later others = none := by
  cases problem : demandProblem ({} : Config) before.facts.escapes cs later others with
  | none => rfl
  | some detail =>
    dsimp [demand, getFacts, StateT.run, StateT.bind, StateT.map, StateT.get] at run
    simp only [pure_bind] at run
    rw [problem] at run
    change Except.error detail = Except.ok (result, after) at run
    contradiction

/-- A successful default record demand (`W{F}`, #1872) passed the whole
demand's four tests, and it keeps the recorded escapes: it differs from
`demand` only in the field set it records. -/
theorem recordDemand_success {fields : List Nat}
    (run : (recordDemand ({} : Config) cs fields later others).run before = .ok (result, after)) :
    demandProblem ({} : Config) before.facts.escapes cs later others = none ∧
      after.facts.escapes = before.facts.escapes := by
  cases problem : demandProblem ({} : Config) before.facts.escapes cs later others with
  | some detail =>
    dsimp [recordDemand, getFacts, StateT.run, StateT.bind, StateT.map, StateT.get] at run
    simp only [pure_bind] at run
    rw [problem] at run
    change Except.error detail = Except.ok (result, after) at run
    contradiction
  | none =>
    refine ⟨rfl, ?_⟩
    dsimp [recordDemand, getFacts, modifyFacts, StateT.run, StateT.bind, StateT.map, StateT.get,
      modify, modifyGet, StateT.modifyGet] at run
    simp only [pure_bind, problem] at run
    change Except.ok ((), _) = Except.ok (result, after) at run
    cases run
    rfl

theorem demand_success_not_escaped
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after)) :
    ∀ origin ∈ cs, ¬ Escaped before.facts.escapes origin :=
  demandProblem_none_not_escaped (demand_success_problem run)

/-- A successful checked demand cannot target any current permanent reader.
The invariant permits observers and aliases; it relates their origins to the
actual checker prefix's recorded escapes. -/
theorem demand_success_no_kept_reaches
    (inv : Invariant ds vs hs env live aenv tenv before.facts.escapes gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after))
    (receiver : named gamma cs root)
    (member : observer ∈ hs.kept.toList) :
    ¬ Reaches hs.heap observer (.ref root) := by
  intro reaches
  obtain ⟨origin, originMember, addressMember⟩ := receiver
  have escaped := inv.keptEscaped observer member root reaches origin addressMember
  exact demand_success_not_escaped run origin originMember escaped

/-- The Dead branch gives the other half of the flat push frame rule. -/
theorem demand_success_live_separate
    (separating : Separating gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after)) :
    ∀ root, named gamma cs root → ¬ named gamma later root :=
  (demandProblem_sound gamma separating ({} : Config) before.facts.escapes cs later others
    (demand_success_problem run)).2.1

mutual
/-- A finite representation exposes every footprint cell through real heap
reachability, including nested record fields and closure captures. -/
theorem represents_footprint_reaches (rep : Represents heap depth value observation footprint) :
    ∀ address ∈ footprint, Reaches heap value (.ref address) := by
  cases rep with
  | int => simp
  | record children =>
    intro address member
    obtain ⟨child, childMember, reachable⟩ := representsMany_footprint_reaches children address member
    exact Reaches.field childMember reachable
  | closure children =>
    intro address member
    obtain ⟨child, childMember, reachable⟩ := representsMany_footprint_reaches children address member
    exact Reaches.capture childMember reachable
  | ref lookup children =>
    intro address member
    rcases List.mem_cons.mp member with same | nested
    · subst address
      exact Reaches.refl _
    · obtain ⟨child, childMember, reachable⟩ := representsMany_footprint_reaches children address nested
      exact Reaches.element lookup childMember reachable

theorem representsMany_footprint_reaches
    (rep : RepresentsMany heap depth values observations footprint) :
    ∀ address ∈ footprint, ∃ value ∈ values, Reaches heap value (.ref address) := by
  cases rep with
  | nil => simp
  | cons head tail =>
    intro address member
    rcases List.mem_append.mp member with first | rest
    · exact ⟨_, by simp, represents_footprint_reaches head address first⟩
    · obtain ⟨child, childMember, reachable⟩ := representsMany_footprint_reaches tail address rest
      exact ⟨child, List.mem_cons_of_mem _ childMember, reachable⟩
end

/-- The outside footprint follows from the checked demand and the observer
invariant. It is not an independent no-alias or empty-observer assumption. -/
theorem demand_success_observer_footprint
    (inv : Invariant ds vs hs env live aenv tenv before.facts.escapes gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after))
    (receiver : named gamma cs root)
    (observers : RepresentsMany hs.heap depth hs.kept.toList observations footprint) :
    root ∉ footprint := by
  intro member
  obtain ⟨observer, observerMember, reachable⟩ :=
    representsMany_footprint_reaches observers root member
  exact demand_success_no_kept_reaches inv run receiver observerMember reachable

/-- A concrete write frames complete permanent observers because the real
checker demand excludes their reachable receiver. Arbitrary other sharing is
legal, and old dead aliases need no observation correspondence. -/
theorem demand_success_observers_after_write
    (inv : Invariant ds vs hs env live aenv tenv before.facts.escapes gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after))
    (receiver : named gamma cs root)
    (observers : RepresentsMany hs.heap depth hs.kept.toList observations footprint) :
    RepresentsMany (hs.heap.set! root stored) depth hs.kept.toList observations footprint :=
  representsMany_after_write observers (demand_success_observer_footprint inv run receiver observers)

theorem demand_success_observer_snapshots_after_write
    (inv : Invariant ds vs hs env live aenv tenv before.facts.escapes gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after))
    (receiver : named gamma cs root)
    (observers : RepresentsMany hs.heap depth hs.kept.toList observations footprint) :
    hs.kept.toList.mapM (snapshot (hs.heap.set! root stored) depth) = .ok observations :=
  snapshots_of_represents (demand_success_observers_after_write inv run receiver observers)

end Ownership.FlatFragment.Support

/-! allocation naming lemmas.
The extension uses the actual next heap address. It preserves every old
address membership and permits one origin to name several allocations. -/

namespace Ownership.FlatFragment.Naming

open Soundness

def NamingBound (gamma : Naming) (bound : Nat) : Prop :=
  ∀ origin address, address ∈ gamma origin → address < bound

def ExtendsAt (gamma next : Naming) (fresh : Origin) (address : Nat) : Prop :=
  ∀ origin cell, cell ∈ next origin ↔
    cell ∈ gamma origin ∨ (origin = fresh ∧ cell = address)

theorem extension_exists (gamma : Naming) (fresh : Origin) (address : Nat) :
    ∃ next, ExtendsAt gamma next fresh address := by
  classical
  refine ⟨fun origin => if origin = fresh then address :: gamma origin else gamma origin, ?_⟩
  intro origin cell
  by_cases same : origin = fresh
  · simp [same, eq_comm, or_comm]
  · simp [same]

theorem extension_old_membership
    (extension : ExtendsAt gamma next fresh bound) (old : cell < bound) :
    cell ∈ next origin ↔ cell ∈ gamma origin := by
  rw [extension origin cell]
  constructor
  · rintro (member | ⟨_, same⟩)
    · exact member
    · omega
  · exact Or.inl

theorem extension_bound
    (bounded : NamingBound gamma bound)
    (extension : ExtendsAt gamma next fresh bound) :
    NamingBound next (bound + 1) := by
  intro origin cell member
  rcases (extension origin cell).mp member with old | ⟨_, same⟩
  · have previous := bounded origin cell old
    omega
  · omega

theorem extension_separating
    (separating : Separating gamma)
    (bounded : NamingBound gamma bound)
    (extension : ExtendsAt gamma next fresh bound)
    (selfAliases : aliases fresh fresh = true) :
    Separating next := by
  intro first second different cell firstMember secondMember
  rcases (extension first cell).mp firstMember with firstOld | ⟨firstFresh, cellNew⟩
  · rcases (extension second cell).mp secondMember with secondOld | ⟨_, cellNew⟩
    · exact separating first second different cell firstOld secondOld
    · have previous := bounded first cell firstOld
      omega
  · rcases (extension second cell).mp secondMember with secondOld | ⟨secondFresh, _⟩
    · have previous := bounded second cell secondOld
      omega
    · subst first
      subst second
      rw [selfAliases] at different
      contradiction

theorem site_self_aliases (site : List Nat) :
    aliases (.site site 0) (.site site 0) = true := by
  change ((site == site) && (0 == 0)) = true
  simp

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- Every origin aliases itself. -/
theorem aliases_self (origin : Origin) : aliases origin origin = true := by
  cases origin <;> simp [aliases]

/-- The naming extended at any origin: a chain case names the copy of the
tail by the input's origins, so the extension is at one of them. -/
theorem origin_allocation_naming
    (bounded : NamingBound gamma heapSize)
    (separating : Separating gamma) (origin : Origin) :
    ∃ next, ExtendsAt gamma next origin heapSize ∧
      NamingBound next (heapSize + 1) ∧ Separating next ∧
      (∀ o cell, cell < heapSize → (cell ∈ next o ↔ cell ∈ gamma o)) := by
  obtain ⟨next, extension⟩ := extension_exists gamma origin heapSize
  exact ⟨next, extension, extension_bound bounded extension,
    extension_separating separating bounded extension (aliases_self origin),
    fun o cell old => extension_old_membership extension old⟩

/-- The caller constructs the extension at the real allocation boundary.
No unused-site or globally alias-free-heap premise enters this theorem. -/
theorem literal_allocation_naming
    (bounded : NamingBound gamma heapSize)
    (separating : Separating gamma) (site : List Nat) :
    ∃ next, ExtendsAt gamma next (.site site 0) heapSize ∧
      NamingBound next (heapSize + 1) ∧ Separating next ∧
      (∀ origin cell, cell < heapSize → (cell ∈ next origin ↔ cell ∈ gamma origin)) := by
  obtain ⟨next, extension⟩ := extension_exists gamma (.site site 0) heapSize
  exact ⟨next, extension, extension_bound bounded extension,
    extension_separating separating bounded extension (site_self_aliases site),
    fun origin cell old => extension_old_membership extension old⟩

end Ownership.FlatFragment.Naming

/-! description support for flat allocated integer lists.

The main theorem keeps the abstract element and certificate arbitrary.
Only the allocated integer payload and its actual named root enter the
premises. No global alias prohibition or empty-observer premise enters.
No theorem uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.Description

open InPlaceSemantics HeapProof Soundness

/- The real `cellsAt` fold deduplicates origins with their existing BEq.
These local proofs justify membership facts for that exact implementation.
They do not replace the checker comparison or export new global instances. -/
local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step :=
  LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin :=
  LawfulBEq.mk (by deriving_LawfulEq_tactic)

/-- Actual union retains every element of either input, including when
its Boolean membership test avoids an insertion. -/
theorem mem_union [BEq α] [LawfulBEq α] (first second : List α) (value : α)
    (member : value ∈ first ∨ value ∈ second) : value ∈ union first second := by
  induction second generalizing first with
  | nil => simpa [union] using member
  | cons head tail ih =>
    change value ∈ union (if first.contains head then first else first ++ [head]) tail
    apply ih
    by_cases present : first.contains head = true
    · rw [if_pos present]
      rcases member with old | added
      · exact Or.inl old
      · rcases List.mem_cons.mp added with same | later
        · exact Or.inl (by simpa [same] using (List.contains_iff_mem.mp present))
        · exact Or.inr later
    · rw [if_neg present]
      rcases member with old | added
      · exact Or.inl (List.mem_append.mpr (Or.inl old))
      · rcases List.mem_cons.mp added with same | later
        · exact Or.inl (List.mem_append.mpr (Or.inr (by simp [same])))
        · exact Or.inr later

private def rootCollector (cells : List Origin) (entry : Path × List Origin) : List Origin :=
  if ([] : Path) == entry.1 then union cells entry.2 else cells

private theorem prefixed_root_fold (paths : List (Path × List Origin)) (initial : List Origin) :
    (paths.map fun (path, cells) => (Step.element :: path, cells)).foldl rootCollector initial =
      initial := by
  induction paths generalizing initial with
  | nil => rfl
  | cons entry paths ih =>
    rcases entry with ⟨path, cells⟩
    simpa [rootCollector] using ih initial

/-- Element paths cannot contribute cells to the root path. Root cells
still pass through the real union operation and can lose duplicate entries. -/
theorem list_root_names (roots : List Origin) (element : Abstract) (certificate : Certificate) :
    namesAt (.list roots element certificate) [] = union [] roots := by
  unfold namesAt
  simp only [Abstract.cellsAt, Abstract.paths, List.foldl_cons]
  change (element.paths.map fun (path, cells) => (Step.element :: path, cells)).foldl
    rootCollector (union [] roots) = union [] roots
  exact prefixed_root_fold element.paths (union [] roots)

theorem named_list_root {root : Nat}
    (rootNamed : named gamma roots root) :
    named gamma (namesAt (.list roots element certificate) []) root := by
  obtain ⟨origin, member, address⟩ := rootNamed
  refine ⟨origin, ?_, address⟩
  rw [list_root_names]
  exact mem_union [] roots origin (Or.inr member)

theorem represents_integer_footprint {heap : Heap}
    (represented : Represents heap depth (.int integer) observation footprint) :
    footprint = [] := by
  cases represented
  rfl

theorem represents_integers_footprint {heap : Heap} (integers : List Int)
    (represented : RepresentsMany heap depth (integers.map Value.int) observations footprint) :
    footprint = [] := by
  induction integers generalizing observations footprint with
  | nil =>
    cases represented
    rfl
  | cons integer integers ih =>
    cases represented with
    | cons first rest =>
      have firstEmpty := represents_integer_footprint first
      have restEmpty := ih rest
      simp only [firstEmpty, restEmpty, List.nil_append]

/-- Every complete expansion retains exactly the allocated root in its
footprint, regardless of its snapshot depth or resulting observation. -/
theorem represents_flat_ref_footprint {heap : Heap} {root : Nat} {integers : List Int}
    (allocated : heap[root]? = some (integers.map Value.int))
    (represented : Represents heap depth (.ref root) observation footprint) :
    footprint = [root] := by
  cases represented with
  | ref current children =>
    rw [allocated] at current
    cases current
    have childrenEmpty := represents_integers_footprint integers children
    simp only [childrenEmpty]

/-- The only paths of the flat reference are its root and one element
step to an integer. No integer contains a further path. -/
theorem atPath_flat_ref {heap : Heap} {root : Nat} {integers : List Int}
    (allocated : heap[root]? = some (integers.map Value.int))
    (located : AtPath heap (.ref root) path value) :
    (path = [] ∧ value = .ref root) ∨
      (∃ integer ∈ integers, path = [.element] ∧ value = .int integer) := by
  cases located with
  | here => exact Or.inl ⟨rfl, rfl⟩
  | element current member child =>
    rw [allocated] at current
    cases current
    obtain ⟨integer, integerMember, rfl⟩ := List.mem_map.mp member
    cases child with
    | here => exact Or.inr ⟨integer, integerMember, rfl, rfl⟩

theorem arrayAt_flat_ref {heap : Heap} {root : Nat} {integers : List Int}
    (allocated : heap[root]? = some (integers.map Value.int))
    (located : ArrayAt heap (.ref root) path address) :
    path = [] ∧ address = root := by
  rcases atPath_flat_ref allocated located with rootPath | integerPath
  · rcases rootPath with ⟨rfl, same⟩
    cases same
    exact ⟨rfl, rfl⟩
  · obtain ⟨integer, _, _, impossible⟩ := integerPath
    cases impossible

theorem no_array_below_flat_ref {heap : Heap} {root : Nat} {integers : List Int}
    (allocated : heap[root]? = some (integers.map Value.int)) :
    ¬ ArrayAt heap (.ref root) (.element :: path) address := by
  intro located
  have impossible := (arrayAt_flat_ref allocated located).1
  cases impossible

/-- Every possible exclusive claim holds for the reachable flat payload.
At the root, its footprint is a singleton. At an integer, it is empty.
The spine clauses have no nested array to inspect. -/
theorem flat_ref_certified {heap : Heap} {root : Nat} {integers : List Int}
    (allocated : heap[root]? = some (integers.map Value.int)) :
    CertifiedExclusive heap abstract (.ref root) := by
  intro path roots element certificate value _shape located depth observation footprint represented
  rcases atPath_flat_ref allocated located with rootPath | integerPath
  · rcases rootPath with ⟨rfl, rfl⟩
    have exactFootprint := represents_flat_ref_footprint allocated represented
    refine ⟨?_, ?_⟩
    · intro _
      simp [exactFootprint]
    · intro _ nextPath address _ found
      exact False.elim (no_array_below_flat_ref allocated found)
  · obtain ⟨integer, _, rfl, rfl⟩ := integerPath
    have exactFootprint := represents_integer_footprint represented
    refine ⟨?_, ?_⟩
    · intro _
      simp [exactFootprint]
    · intro _ nextPath address _ found
      cases found

/-- An allocated flat integer list has the requested description whenever
the abstract root names its concrete address. The abstract element and both
certificate bits remain arbitrary. Other values can share the same root. -/
theorem allocated_list_described {heap : Heap} {root : Nat} {integers : List Int}
    (allocated : heap[root]? = some (integers.map Value.int))
    (rootNamed : named gamma roots root) :
    Describes gamma heap (.list roots element certificate) (.ref root) := by
  refine ⟨⟨?_, flat_ref_certified allocated⟩, ?_⟩
  · intro path address located
    obtain ⟨rfl, rfl⟩ := arrayAt_flat_ref allocated located
    exact named_list_root rootNamed
  · apply ClosureAgreement.array allocated
    intro value member
    obtain ⟨integer, _, rfl⟩ := List.mem_map.mp member
    exact ClosureAgreement.int _ integer

end Ownership.FlatFragment.Description

/-! state relation for the flat ANF proof.

The relation extends the existing prefix invariant. It records concrete
shape, allocation, and observer facts that the expression induction needs.
Only live bindings require observation correspondence. A dead list binding
can retain an old value observation after its heap array changes.

The initial theorem uses the ordinary closed-program runtime states.
The generic relation permits nonempty heaps and permanent observers.
It does not assume final result correspondence or a global alias prohibition.
No theorem below uses a pinned soundness obligation.
-/

namespace Ownership.FlatFragment.State

open InPlaceSemantics HeapProof Soundness

/-- The static shapes of the fragment's abstracts. A bottom is the abstract
of dead code: the checker binds it where it has no information (the head of
a chain case whose chain is statically empty, the slot a result constructor
leaves empty), and it flows through records, result slots and the joins of
a skipped case; a runtime binding never holds one where its value is (the
tags, `ResultTags`, say so). List descriptions carry flat element abstracts,
including bottom for empty lists. Dead aliases keep their old element description
after a write.
The relation does not require uniqueness of a root or prohibit sharing
between runtime bindings. A list's roots hold no unknown origin (the join of
mismatched shapes, which two abstracts of one flat type never make): what a
list names below an element step is then what its element names. A record is described field by field. A result is
a record of a scalar tag and two payload slots, each the shape of its type
or bottom. -/
inductive FlatAbstract : Ty → Abstract → Prop where
  | bottom (ty : Ty) : FlatAbstract ty .bottom
  | int : FlatAbstract .int .scalar
  | list (t : Ty) (roots : List Origin) (element : Abstract) (certificate : Certificate) :
      Origin.unknown ∉ roots → FlatAbstract t element →
      FlatAbstract (.list t) (.list roots element certificate)
  | dict (t : Ty) (roots : List Origin) (value : Abstract) (certificate : Certificate) :
      Origin.unknown ∉ roots → FlatAbstract t value →
      FlatAbstract (.dict t) (.list roots value certificate)
  | chainBottom (roots : List Origin) (certificate : Certificate) :
      FlatAbstract (.chain .int) (.list roots .bottom certificate)
  | chainScalar (roots : List Origin) (certificate : Certificate) :
      FlatAbstract (.chain .int) (.list roots .scalar certificate)
  | record (ts : List Ty) (as : List Abstract) : ts.length = as.length →
      (∀ (i : Nat) (t : Ty) (a : Abstract), ts[i]? = some t → as[i]? = some a → FlatAbstract t a) →
      FlatAbstract (.record ts) (.record as)
  | result (error success : Ty) (ae aa : Abstract) :
      FlatAbstract error ae → FlatAbstract success aa →
      FlatAbstract (.result error success) (.record [.scalar, ae, aa])
  /-- A record object (#316) is a one-slot array whose element is the
  record: a list description whose element is the record's abstract. -/
  | object (ts : List Ty) (roots : List Origin) (element : Abstract) (certificate : Certificate) :
      Origin.unknown ∉ roots → FlatAbstract (.record ts) element →
      FlatAbstract (.object ts) (.list roots element certificate)

/-- Fields of flat abstracts, read through their types, are the same fields. -/
theorem entryFields_of_flat {ds : List Decl} :
    ∀ (ts : List Ty) (as : List Abstract), ts.length = as.length →
      (∀ (i : Nat) (t : Ty) (a : Abstract), ts[i]? = some t → as[i]? = some a →
        entryAbstract ds t a = a) →
      entryFields ds ts as = as
  | [], [], _, _ => rfl
  | t :: ts, a :: as, lengths, fields => by
    show entryAbstract ds t a :: entryFields ds ts as = a :: as
    rw [fields 0 t a rfl rfl,
      entryFields_of_flat ts as (by simpa using lengths)
        (fun i t' a' ht ha => fields (i + 1) t' a' ht ha)]
  | [], _ :: _, lengths, _ => by simp at lengths
  | _ :: _, [], lengths, _ => by simp at lengths

theorem entryAbstract_bottom (ds : List Decl) (t : Ty) : entryAbstract ds t .bottom = .bottom := by
  cases t <;> rfl

theorem entryAbstract_scalar (ds : List Decl) (t : Ty) : entryAbstract ds t .scalar = .scalar := by
  cases t <;> rfl

theorem entryAbstract_symbolic (ds : List Decl) (t : Ty) (slot : Nat) (ty : Ty) (cs es : List Origin) :
    entryAbstract ds t (.symbolic slot ty cs es) = .symbolic slot ty cs es := by
  cases t <;> rfl

theorem entryAbstract_function (ds : List Decl) (t : Ty) (cs : List Origin)
    (alts : List (Nat × List Abstract)) :
    entryAbstract ds t (.function cs alts) = .function cs (entryAlternatives ds alts) := by
  cases t <;> rfl

theorem entryAbstract_list (ds : List Decl) (t : Ty) (cs : List Origin) (x : Abstract)
    (ex : Certificate) : ∃ y, entryAbstract ds t (.list cs x ex) = .list cs y ex := by
  cases t <;> exact ⟨_, rfl⟩

theorem entryAbstract_list_list (ds : List Decl) (t : Ty) (cs : List Origin) (x : Abstract)
    (ex : Certificate) : entryAbstract ds (.list t) (.list cs x ex) = .list cs (entryAbstract ds t x) ex := rfl

theorem entryAbstract_dict_list (ds : List Decl) (t : Ty) (cs : List Origin) (x : Abstract)
    (ex : Certificate) :
    entryAbstract ds (.dict t) (.list cs x ex) = .list cs (.record [.scalar, entryAbstract ds t x]) ex := rfl

theorem entryType_list (t : Ty) : entryType (.list t) = .list (entryType t) := rfl

theorem entryType_dict (t : Ty) : entryType (.dict t) = .list (.record [.int, entryType t]) := rfl

theorem entryAbstract_record (ds : List Decl) (t : Ty) (xs : List Abstract) :
    ∃ ys, entryAbstract ds t (.record xs) = .record ys := by
  cases t <;> exact ⟨_, rfl⟩

/-- Field `i` of fields read through their types is field `i` read through
    type `i` (`Int` past the types). -/
theorem entryFields_getElem? (ds : List Decl) :
    ∀ (ts : List Ty) (xs : List Abstract) (i : Nat),
      (entryFields ds ts xs)[i]? = xs[i]?.map (entryAbstract ds (ts[i]?.getD .int))
  | ts, [], i => by cases ts <;> rfl
  | [], x :: xs, 0 => rfl
  | [], x :: xs, i + 1 => by
    show (entryFields ds [] xs)[i]? = _
    rw [entryFields_getElem? ds [] xs i]
    rfl
  | t :: ts, x :: xs, 0 => rfl
  | t :: ts, x :: xs, i + 1 => by
    show (entryFields ds ts xs)[i]? = _
    rw [entryFields_getElem? ds ts xs i]
    rfl

theorem entryFields_length (ds : List Decl) :
    ∀ (ts : List Ty) (xs : List Abstract), (entryFields ds ts xs).length = xs.length
  | ts, [] => by cases ts <;> rfl
  | [], _ :: xs => by
    show (entryFields ds [] xs).length + 1 = xs.length + 1
    rw [entryFields_length ds [] xs]
  | _ :: ts, _ :: xs => by
    show (entryFields ds ts xs).length + 1 = xs.length + 1
    rw [entryFields_length ds ts xs]

theorem entryTypes_getElem? : ∀ (ts : List Ty) (i : Nat), (entryTypes ts)[i]? = ts[i]?.map entryType
  | [], _ => rfl
  | _ :: _, 0 => rfl
  | _ :: ts, i + 1 => by
    show (entryTypes ts)[i]? = _
    rw [entryTypes_getElem? ts i]
    rfl

theorem entryTypes_length : ∀ (ts : List Ty), (entryTypes ts).length = ts.length
  | [] => rfl
  | _ :: ts => by
    show (entryTypes ts).length + 1 = ts.length + 1
    rw [entryTypes_length ts]

theorem entryTypes_index {ts : List Ty} {i : Nat} {t : Ty} (found : ts[i]? = some t) :
    (entryTypes ts)[i]? = some (entryType t) := by
  rw [entryTypes_getElem?, found]; rfl

theorem entryTypes_index_inv {ts : List Ty} {i : Nat} {t' : Ty} (found : (entryTypes ts)[i]? = some t') :
    ∃ t, ts[i]? = some t ∧ t' = entryType t := by
  rw [entryTypes_getElem?] at found
  cases original : ts[i]? with
  | none => rw [original] at found; cases found
  | some t => rw [original] at found; exact ⟨t, rfl, (Option.some.inj found).symm⟩

theorem entryFields_index {ds : List Decl} {ts : List Ty} {as : List Abstract} {i : Nat} {t : Ty} {a : Abstract}
    (typeAt : ts[i]? = some t) (found : as[i]? = some a) :
    (entryFields ds ts as)[i]? = some (entryAbstract ds t a) := by
  rw [entryFields_getElem?, found, typeAt]; rfl

theorem entryFields_index_inv {ds : List Decl} {ts : List Ty} {as : List Abstract} {i : Nat} {a' : Abstract}
    (found : (entryFields ds ts as)[i]? = some a') :
    ∃ a, as[i]? = some a ∧ a' = entryAbstract ds (ts[i]?.getD .int) a := by
  rw [entryFields_getElem?] at found
  cases original : as[i]? with
  | none => rw [original] at found; cases found
  | some a => rw [original] at found; exact ⟨a, rfl, (Option.some.inj found).symm⟩

/-- A type with no dictionary is its own representation. -/
theorem entryType_of_dictFree {t : Ty} (free : DictFree t) : entryType t = t := by
  induction free with
  | int => rfl
  | list t _ ih => show Ty.list (entryType t) = _; rw [ih]
  | chain t _ ih => show Ty.chain (entryType t) = _; rw [ih]
  | builder t _ ih => show Ty.builder (entryType t) = _; rw [ih]
  | record ts _ ih =>
    show Ty.record (entryTypes ts) = _
    congr 1
    apply List.ext_getElem?
    intro i
    rw [entryTypes_getElem?]
    cases found : ts[i]? with
    | none => rfl
    | some t' => simp only [Option.map_some]; rw [ih t' (List.mem_of_getElem? found)]
  | result e a _ _ ihE ihA => show Ty.result (entryType e) (entryType a) = _; rw [ihE, ihA]
  | fn ps r => rfl
  | object ts _ ih =>
    show Ty.object (entryTypes ts) = _
    congr 1
    apply List.ext_getElem?
    intro i
    rw [entryTypes_getElem?]
    cases found : ts[i]? with
    | none => rfl
    | some t' => simp only [Option.map_some]; rw [ih t' (List.mem_of_getElem? found)]

/-- A representation holds no dictionary. -/
theorem dictFree_entryType : ∀ (t : Ty), DictFree (entryType t)
  | .dict t => .list _ (.record _ (by
      intro t' member
      simp only [List.mem_cons, List.not_mem_nil, or_false] at member
      rcases member with rfl | rfl
      · exact .int
      · exact dictFree_entryType t))
  | .list t => .list _ (dictFree_entryType t)
  | .chain t => .chain _ (dictFree_entryType t)
  | .builder t => .builder _ (dictFree_entryType t)
  | .record ts => .record _ (by
      intro t' member
      obtain ⟨i, found⟩ := List.mem_iff_getElem?.mp member
      rw [entryTypes_getElem?] at found
      cases original : ts[i]? with
      | none => rw [original] at found; cases found
      | some t0 =>
        rw [original] at found
        cases Option.some.inj found
        have : sizeOf t0 < 1 + sizeOf ts := by
          have := List.sizeOf_lt_of_mem (List.mem_of_getElem? original)
          omega
        exact dictFree_entryType t0)
  | .result e a => .result _ _ (dictFree_entryType e) (dictFree_entryType a)
  | .int => .int
  | .fn ps r => .fn ps r
  | .object ts => .object _ (by
      intro t' member
      obtain ⟨i, found⟩ := List.mem_iff_getElem?.mp member
      rw [entryTypes_getElem?] at found
      cases original : ts[i]? with
      | none => rw [original] at found; cases found
      | some t0 =>
        rw [original] at found
        cases Option.some.inj found
        have : sizeOf t0 < 1 + sizeOf ts := by
          have := List.sizeOf_lt_of_mem (List.mem_of_getElem? original)
          omega
        exact dictFree_entryType t0)
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals omega

/-- A flat type's representation is flat. -/
theorem flatType_entryType {t : Ty} (flat : FlatType t) : FlatType (entryType t) := by
  induction flat with
  | int => exact .int
  | list t _ ih => exact .list _ ih
  | chainInt => exact .chainInt
  | record ts _ ih =>
    refine .record _ ?_
    intro t' member
    obtain ⟨i, found⟩ := List.mem_iff_getElem?.mp member
    rw [entryTypes_getElem?] at found
    cases original : ts[i]? with
    | none => rw [original] at found; cases found
    | some t0 =>
      rw [original] at found
      cases Option.some.inj found
      exact ih t0 (List.mem_of_getElem? original)
  | result e a _ _ ihE ihA => exact .result _ _ ihE ihA
  | dict t _ ih =>
    refine .list _ (.record _ ?_)
    intro t' member
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl
    · exact .int
    · exact ih
  | object ts _ ih =>
    refine .object _ ?_
    intro t' member
    obtain ⟨i, found⟩ := List.mem_iff_getElem?.mp member
    rw [entryTypes_getElem?] at found
    cases original : ts[i]? with
    | none => rw [original] at found; cases found
    | some t0 =>
      rw [original] at found
      cases Option.some.inj found
      exact ih t0 (List.mem_of_getElem? original)

/-- A flat abstract with no dictionary in its type is its own representation
    (#1796). -/
theorem entryAbstract_of_dictFree {ds : List Decl} {t : Ty} {a : Abstract}
    (free : DictFree t) (shape : FlatAbstract t a) : entryAbstract ds t a = a := by
  induction shape with
  | bottom ty => exact entryAbstract_bottom ds ty
  | int => rfl
  | list t roots element certificate _ _ ih =>
    show Abstract.list roots (entryAbstract ds t element) certificate = _
    cases free with
    | list _ free' => rw [ih free']
  | dict t roots value certificate _ _ _ => cases free
  | chainBottom roots certificate => rfl
  | chainScalar roots certificate => rfl
  | record ts as lengths _ ih =>
    show Abstract.record (entryFields ds ts as) = _
    cases free with
    | record _ fieldsFree =>
      rw [entryFields_of_flat ts as lengths
        (fun i t' a' ht ha => ih i t' a' ht ha (fieldsFree t' (List.mem_of_getElem? ht)))]
  | result error success ae aa _ _ ihError ihSuccess =>
    cases free with
    | result _ _ freeError freeSuccess =>
      show Abstract.record [entryAbstract ds .int .scalar, entryAbstract ds error ae,
        entryAbstract ds success aa] = _
      rw [ihError freeError, ihSuccess freeSuccess]
      rfl
  | object ts roots element certificate _ _ ih =>
    show Abstract.list roots (entryAbstract ds (.record ts) element) certificate = _
    cases free with
    | object _ fieldsFree => rw [ih (.record _ fieldsFree)]

/-- The representation of a flat abstract is a flat abstract of the
    representation type. -/
theorem flatAbstract_entry {ds : List Decl} {t : Ty} {a : Abstract} (shape : FlatAbstract t a) :
    FlatAbstract (entryType t) (entryAbstract ds t a) := by
  induction shape with
  | bottom ty => rw [entryAbstract_bottom]; exact .bottom _
  | int => exact .int
  | list t roots element certificate noUnk _ ih => exact .list _ roots _ certificate noUnk ih
  | dict t roots value certificate noUnk _ ih =>
    refine .list _ roots _ certificate noUnk (.record _ _ rfl ?_)
    intro i t' a' ht ha
    match i, ht, ha with
    | 0, ht, ha =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at ht ha
      subst ht; subst ha
      exact .int
    | 1, ht, ha =>
      simp only [List.getElem?_cons_succ, List.getElem?_cons_zero, Option.some.injEq] at ht ha
      subst ht; subst ha
      exact ih
    | _ + 2, ht, _ => simp at ht
  | chainBottom roots certificate => exact .chainBottom roots certificate
  | chainScalar roots certificate => exact .chainScalar roots certificate
  | record ts as lengths _ ih =>
    refine .record _ _ (by rw [entryTypes_length, entryFields_length, lengths]) ?_
    intro i t' a' ht ha
    rw [entryTypes_getElem?] at ht
    rw [entryFields_getElem?] at ha
    cases foundT : ts[i]? with
    | none => rw [foundT] at ht; cases ht
    | some t0 =>
      rw [foundT] at ht ha
      cases Option.some.inj ht
      cases foundA : as[i]? with
      | none => rw [foundA] at ha; cases ha
      | some a0 =>
        rw [foundA] at ha
        simp only [Option.map_some, Option.getD_some, Option.some.injEq] at ha
        subst ha
        exact ih i t0 a0 foundT foundA
  | result error success ae aa _ _ ihError ihSuccess => exact .result _ _ _ _ ihError ihSuccess
  | object ts roots element certificate noUnk _ ih => exact .object _ roots _ certificate noUnk ih

/-- The runtime shapes of a binding's abstract, and the tags of its result
values. A binding that holds a value is live code, so its abstract is not
bottom: an integer's is the scalar, a list's a list description. Both
interpreters build a success as `[1, 0, x]` and an error as `[0, x, 0]`. The
checker builds `ok x` with a bottom error slot and `err x` with a bottom
success slot, and skips a case arm whose slot is bottom; so a success is
described with a success slot that is not bottom, an error with an error
slot that is not bottom, through records and through the live payload. The
relation reads no heap, so a write keeps it. -/
inductive ResultTags : Ty → Abstract → Value → Prop where
  | int (n : Int) : ResultTags .int .scalar (.int n)
  | list (t : Ty) (roots : List Origin) (element : Abstract) (certificate : Certificate) (w : Value) :
      ResultTags (.list t) (.list roots element certificate) w
  | chainInt (roots : List Origin) (element : Abstract) (certificate : Certificate) (w : Value) :
      ResultTags (.chain .int) (.list roots element certificate) w
  | record (ts : List Ty) (as : List Abstract) (ws : List Value) : ts.length = as.length →
      (∀ (i : Nat) (t : Ty) (a : Abstract) (w : Value),
        ts[i]? = some t → as[i]? = some a → ws[i]? = some w → ResultTags t a w) →
      ResultTags (.record ts) (.record as) (.record ws)
  | ok (error success : Ty) (tag ae aa : Abstract) (w : Value) :
      aa ≠ .bottom → ResultTags success aa w →
      ResultTags (.result error success) (.record [tag, ae, aa]) (.record [.int 1, .int 0, w])
  | err (error success : Ty) (tag ae aa : Abstract) (w : Value) :
      ae ≠ .bottom → ResultTags error ae w →
      ResultTags (.result error success) (.record [tag, ae, aa]) (.record [.int 0, w, .int 0])
  | object (ts : List Ty) (roots : List Origin) (element : Abstract) (certificate : Certificate) (w : Value) :
      ResultTags (.object ts) (.list roots element certificate) w

/-- The chain tags of a binding's abstract and its observation. The checker
builds `endChain` with a bottom element and `link` with a scalar one, and a
join keeps a bottom element only when both sides have one; so a chain whose
element abstract is bottom is empty on the value side, through records and
the live slot of a result. A chain case binds its head to the element
abstract, so the relation says that an arm the runtime takes binds a scalar.
The relation reads no heap, so a write keeps it. -/
inductive ChainTags : Ty → Abstract → Observation → Prop where
  | int (a : Abstract) (o : Observation) : ChainTags .int a o
  | list (t : Ty) (a : Abstract) (o : Observation) : ChainTags (.list t) a o
  | chainScalar (roots : List Origin) (certificate : Certificate) (o : Observation) :
      ChainTags (.chain .int) (.list roots .scalar certificate) o
  | chainBottom (roots : List Origin) (certificate : Certificate) :
      ChainTags (.chain .int) (.list roots .bottom certificate) (.list [])
  | record (ts : List Ty) (as : List Abstract) (os : List Observation) : ts.length = as.length →
      (∀ (i : Nat) (t : Ty) (a : Abstract) (o : Observation),
        ts[i]? = some t → as[i]? = some a → os[i]? = some o → ChainTags t a o) →
      ChainTags (.record ts) (.record as) (.record os)
  | ok (error success : Ty) (tag ae aa : Abstract) (o : Observation) :
      ChainTags success aa o →
      ChainTags (.result error success) (.record [tag, ae, aa]) (.record [.int 1, .int 0, o])
  | err (error success : Ty) (tag ae aa : Abstract) (o : Observation) :
      ChainTags error ae o →
      ChainTags (.result error success) (.record [tag, ae, aa]) (.record [.int 0, o, .int 0])
  | object (ts : List Ty) (a : Abstract) (o : Observation) : ChainTags (.object ts) a o

/-- Tags inside arrays, through records and the active payload of a result.
Each array element has result tags and chain tags for every corresponding
observation. The relation follows nested arrays as well. Integer chains have
no nested arrays; their own emptiness tag stays in `ChainTags`. -/
inductive TagsDeep (heap : Heap) : Ty → Abstract → Value → Prop where
  | int (a : Abstract) (w : Value) : TagsDeep heap .int a w
  | chain (a : Abstract) (w : Value) : TagsDeep heap (.chain .int) a w
  | list (root : Nat) (ws : List Value) (t : Ty) (roots : List Origin)
      (element : Abstract) (certificate : Certificate) :
      heap[root]? = some ws →
      (∀ w ∈ ws, ResultTags t element w) →
      (∀ w ∈ ws, ∀ o, Corresponds heap o w → ChainTags t element o) →
      (∀ w ∈ ws, TagsDeep heap t element w) →
      TagsDeep heap (.list t) (.list roots element certificate) (.ref root)
  | record (ts : List Ty) (as : List Abstract) (ws : List Value) :
      ts.length = as.length →
      (∀ (i : Nat) (t : Ty) (a : Abstract) (w : Value), ts[i]? = some t → as[i]? = some a → ws[i]? = some w →
        TagsDeep heap t a w) →
      TagsDeep heap (.record ts) (.record as) (.record ws)
  | ok (error success : Ty) (tag ae aa : Abstract) (w : Value) :
      TagsDeep heap success aa w →
      TagsDeep heap (.result error success) (.record [tag, ae, aa]) (.record [.int 1, .int 0, w])
  | err (error success : Ty) (tag ae aa : Abstract) (w : Value) :
      TagsDeep heap error ae w →
      TagsDeep heap (.result error success) (.record [tag, ae, aa]) (.record [.int 0, w, .int 0])
  /-- A record object (#316): the tags of its one slot, as for a list's
  elements. -/
  | object (root : Nat) (ws : List Value) (ts : List Ty) (roots : List Origin)
      (element : Abstract) (certificate : Certificate) :
      heap[root]? = some ws →
      (∀ w ∈ ws, ResultTags (.record ts) element w) →
      (∀ w ∈ ws, ∀ o, Corresponds heap o w → ChainTags (.record ts) element o) →
      (∀ w ∈ ws, TagsDeep heap (.record ts) element w) →
      TagsDeep heap (.object ts) (.list roots element certificate) (.ref root)

/-! ## A heap typing (#169)

The relation types a live value at its representation (`entryType`), where
a dictionary of `t` and a list of `{Int, t}` records have one shape. A heap
typing `kinds` keeps the source type of every typed array. An array holds
values of its element type, a binding's value has its declared type, and both
ends of a link are lists of one type. So no link names a dictionary's array,
and a dictionary write is never a linked write. The value relation reads no
heap: a reference has the type that the map gives its array. -/

/-- A runtime value has a source type under a heap typing. -/
inductive Kinded (kinds : Nat → Option Ty) : Ty → Value → Prop where
  | int (i : Int) : Kinded kinds .int (.int i)
  | list (t : Ty) (c : Nat) : kinds c = some (.list t) → Kinded kinds (.list t) (.ref c)
  | chain (t : Ty) (c : Nat) : kinds c = some (.chain t) → Kinded kinds (.chain t) (.ref c)
  | dict (t : Ty) (c : Nat) : kinds c = some (.dict t) → Kinded kinds (.dict t) (.ref c)
  | object (ts : List Ty) (c : Nat) : kinds c = some (.object ts) → Kinded kinds (.object ts) (.ref c)
  | record (ts : List Ty) (ws : List Value) : ws.length = ts.length →
      (∀ (i : Nat) (t : Ty) (w : Value), ts[i]? = some t → ws[i]? = some w → Kinded kinds t w) →
      Kinded kinds (.record ts) (.record ws)
  | ok (error success : Ty) (w : Value) : Kinded kinds success w →
      Kinded kinds (.result error success) (.record [.int 1, .int 0, w])
  | err (error success : Ty) (w : Value) : Kinded kinds error w →
      Kinded kinds (.result error success) (.record [.int 0, w, .int 0])

/-- The contents of an array of a source type: a list's and a chain's
elements have the element type, and a dictionary's entries are records
`[key, value]` whose value has the value type. -/
inductive ContentsKinded (kinds : Nat → Option Ty) : Ty → List Value → Prop where
  | list (t : Ty) (xs : List Value) : (∀ x ∈ xs, Kinded kinds t x) → ContentsKinded kinds (.list t) xs
  | chain (t : Ty) (xs : List Value) : (∀ x ∈ xs, Kinded kinds t x) → ContentsKinded kinds (.chain t) xs
  | dict (t : Ty) (xs : List Value) :
      (∀ x ∈ xs, ∃ (k : Int) (v : Value), x = .record [.int k, v] ∧ Kinded kinds t v) →
      ContentsKinded kinds (.dict t) xs
  /-- A record object (#316) has exactly one slot, its record. -/
  | object (ts : List Ty) (x : Value) : Kinded kinds (.record ts) x →
      ContentsKinded kinds (.object ts) [x]

/-- A heap typing of a state: every typed array exists and holds contents of
its type, both ends of every link are lists of one element type, and every
binding, live or dead, has its declared type. -/
structure StateKinded (kinds : Nat → Option Ty) (hs : InPlaceSemantics.State)
    (env : List (Var × Observation × Value)) (tenv : Env Ty) : Prop where
  heap : ∀ c t, kinds c = some t → ∃ xs, hs.heap[c]? = some xs ∧ ContentsKinded kinds t xs
  links : ∀ v s front, (v, s, front) ∈ hs.links →
    ∃ t, kinds v = some (.list t) ∧ kinds s = some (.list t)
  env : ∀ x ty o w, tenv.lookup x = some ty → env.lookup x = some (o, w) → Kinded kinds ty w

/-- What a step concludes of its result: one heap typing of the state after
it types every binding and the result. -/
def KindsAt (hs : InPlaceSemantics.State) (env : List (Var × Observation × Value)) (tenv : Env Ty)
    (type : Ty) (actual : Value) : Prop :=
  ∃ kinds, StateKinded kinds hs env tenv ∧ Kinded kinds type actual

theorem kinded_mono {kinds kinds' : Nat → Option Ty}
    (mono : ∀ c t, kinds c = some t → kinds' c = some t) :
    ∀ {t : Ty} {w : Value}, Kinded kinds t w → Kinded kinds' t w := by
  intro t w typed
  induction typed with
  | int i => exact .int i
  | list t c found => exact .list t c (mono c _ found)
  | chain t c found => exact .chain t c (mono c _ found)
  | dict t c found => exact .dict t c (mono c _ found)
  | object ts c found => exact .object ts c (mono c _ found)
  | record ts ws lengths _ ih => exact .record ts ws lengths ih
  | ok error success w _ ih => exact .ok error success w ih
  | err error success w _ ih => exact .err error success w ih

theorem contentsKinded_mono {kinds kinds' : Nat → Option Ty}
    (mono : ∀ c t, kinds c = some t → kinds' c = some t) {t : Ty} {xs : List Value}
    (contents : ContentsKinded kinds t xs) : ContentsKinded kinds' t xs := by
  cases contents with
  | list t xs typed => exact .list t xs fun x member => kinded_mono mono (typed x member)
  | chain t xs typed => exact .chain t xs fun x member => kinded_mono mono (typed x member)
  | dict t xs typed =>
    refine .dict t xs fun x member => ?_
    obtain ⟨k, v, shape, typedV⟩ := typed x member
    exact ⟨k, v, shape, kinded_mono mono typedV⟩
  | object ts x typed => exact .object ts x (kinded_mono mono typed)

/-- A typed array is allocated. -/
theorem StateKinded.bound {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {t : Ty} (typed : kinds c = some t) :
    c < hs.heap.size := by
  obtain ⟨xs, lookup, _⟩ := state.heap c t typed
  exact (Array.getElem?_eq_some_iff.mp lookup).1

/-- An integer has no array. -/
theorem kinded_int_inv {kinds : Nat → Option Ty} {w : Value} (typed : Kinded kinds .int w) :
    ∃ i, w = .int i := by
  cases typed with
  | int i => exact ⟨i, rfl⟩

/-- A list has the root that the map types as that list. -/
theorem kinded_list_inv {kinds : Nat → Option Ty} {t : Ty} {w : Value} (typed : Kinded kinds (.list t) w) :
    ∃ c, w = .ref c ∧ kinds c = some (.list t) := by
  cases typed with
  | list t c found => exact ⟨c, rfl, found⟩

theorem kinded_chain_inv {kinds : Nat → Option Ty} {t : Ty} {w : Value} (typed : Kinded kinds (.chain t) w) :
    ∃ c, w = .ref c ∧ kinds c = some (.chain t) := by
  cases typed with
  | chain t c found => exact ⟨c, rfl, found⟩

theorem kinded_dict_inv {kinds : Nat → Option Ty} {t : Ty} {w : Value} (typed : Kinded kinds (.dict t) w) :
    ∃ c, w = .ref c ∧ kinds c = some (.dict t) := by
  cases typed with
  | dict t c found => exact ⟨c, rfl, found⟩

theorem kinded_object_inv {kinds : Nat → Option Ty} {ts : List Ty} {w : Value}
    (typed : Kinded kinds (.object ts) w) :
    ∃ c, w = .ref c ∧ kinds c = some (.object ts) := by
  cases typed with
  | object ts c found => exact ⟨c, rfl, found⟩

theorem kinded_record_inv {kinds : Nat → Option Ty} {ts : List Ty} {w : Value}
    (typed : Kinded kinds (.record ts) w) :
    ∃ ws, w = .record ws ∧ ws.length = ts.length ∧
      ∀ (i : Nat) (t : Ty) (x : Value), ts[i]? = some t → ws[i]? = some x → Kinded kinds t x := by
  cases typed with
  | record ts ws lengths fields => exact ⟨ws, rfl, lengths, fields⟩

theorem kinded_result_inv {kinds : Nat → Option Ty} {error success : Ty} {w : Value}
    (typed : Kinded kinds (.result error success) w) :
    (∃ x, w = .record [.int 1, .int 0, x] ∧ Kinded kinds success x) ∨
      (∃ x, w = .record [.int 0, x, .int 0] ∧ Kinded kinds error x) := by
  cases typed with
  | ok error success x typedX => exact Or.inl ⟨x, rfl, typedX⟩
  | err error success x typedX => exact Or.inr ⟨x, rfl, typedX⟩

/-- The payload of a success has the success type. -/
theorem kinded_ok_payload {kinds : Nat → Option Ty} {error success : Ty} {w : Value}
    (typed : Kinded kinds (.result error success) (.record [.int 1, .int 0, w])) : Kinded kinds success w := by
  rcases kinded_result_inv typed with ⟨x, same, typedX⟩ | ⟨x, same, _⟩
  · simp only [Value.record.injEq, List.cons.injEq] at same
    rw [same.2.2.1]
    exact typedX
  · simp at same

/-- The payload of an error has the error type. -/
theorem kinded_err_payload {kinds : Nat → Option Ty} {error success : Ty} {w : Value}
    (typed : Kinded kinds (.result error success) (.record [.int 0, w, .int 0])) : Kinded kinds error w := by
  rcases kinded_result_inv typed with ⟨x, same, _⟩ | ⟨x, same, typedX⟩
  · simp at same
  · simp only [Value.record.injEq, List.cons.injEq] at same
    rw [same.2.1]
    exact typedX

/-- The contents of an array that the map types as a list. -/
theorem StateKinded.list_contents {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {t : Ty} (typed : kinds c = some (.list t))
    {xs : List Value} (lookup : hs.heap[c]? = some xs) : ∀ x ∈ xs, Kinded kinds t x := by
  obtain ⟨ys, lookup', contents⟩ := state.heap c _ typed
  rw [lookup] at lookup'
  cases Option.some.inj lookup'
  cases contents with
  | list t xs typed => exact typed

theorem StateKinded.chain_contents {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {t : Ty} (typed : kinds c = some (.chain t))
    {xs : List Value} (lookup : hs.heap[c]? = some xs) : ∀ x ∈ xs, Kinded kinds t x := by
  obtain ⟨ys, lookup', contents⟩ := state.heap c _ typed
  rw [lookup] at lookup'
  cases Option.some.inj lookup'
  cases contents with
  | chain t xs typed => exact typed

theorem StateKinded.dict_contents {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {t : Ty} (typed : kinds c = some (.dict t))
    {xs : List Value} (lookup : hs.heap[c]? = some xs) :
    ∀ x ∈ xs, ∃ (k : Int) (v : Value), x = .record [.int k, v] ∧ Kinded kinds t v := by
  obtain ⟨ys, lookup', contents⟩ := state.heap c _ typed
  rw [lookup] at lookup'
  cases Option.some.inj lookup'
  cases contents with
  | dict t xs typed => exact typed

/-- No link names an array that the map types as a dictionary. -/
theorem StateKinded.dict_unlinked {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {t : Ty} (typed : kinds c = some (.dict t)) :
    ∀ v s front, (v, s, front) ∈ hs.links → v ≠ c ∧ s ≠ c := by
  intro v s front member
  obtain ⟨u, viewTyped, sourceTyped⟩ := state.links v s front member
  constructor
  · intro same
    subst same
    rw [typed] at viewTyped
    cases viewTyped
  · intro same
    subst same
    rw [typed] at sourceTyped
    cases sourceTyped

/-- A record object's array has exactly one slot, its record (#316). -/
theorem StateKinded.object_slot {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {ts : List Ty} (typed : kinds c = some (.object ts)) :
    ∃ x, hs.heap[c]? = some [x] ∧ Kinded kinds (.record ts) x := by
  obtain ⟨ys, lookup, contents⟩ := state.heap c _ typed
  cases contents with
  | object ts x typedX => exact ⟨x, lookup, typedX⟩

theorem StateKinded.object_contents {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {ts : List Ty} (typed : kinds c = some (.object ts))
    {xs : List Value} (lookup : hs.heap[c]? = some xs) :
    ∀ x ∈ xs, Kinded kinds (.record ts) x := by
  obtain ⟨y, lookup', typedY⟩ := state.object_slot typed
  rw [lookup] at lookup'
  cases Option.some.inj lookup'
  intro x member
  simp only [List.mem_singleton] at member
  subst member
  exact typedY

/-- No link names an array that the map types as a record object: an update
writes its object with a plain write (#316). -/
theorem StateKinded.object_unlinked {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {c : Nat} {ts : List Ty} (typed : kinds c = some (.object ts)) :
    ∀ v s front, (v, s, front) ∈ hs.links → v ≠ c ∧ s ≠ c := by
  intro v s front member
  obtain ⟨u, viewTyped, sourceTyped⟩ := state.links v s front member
  constructor
  · intro same
    subst same
    rw [typed] at viewTyped
    cases viewTyped
  · intro same
    subst same
    rw [typed] at sourceTyped
    cases sourceTyped

/-- The same heap typing holds of a state with the same typed arrays and
links. -/
theorem StateKinded.of_heap {kinds : Nat → Option Ty} {hs hs' : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv)
    (heap : ∀ c t, kinds c = some t → hs'.heap[c]? = hs.heap[c]?) (links : hs'.links = hs.links) :
    StateKinded kinds hs' env tenv := by
  refine ⟨?_, ?_, state.env⟩
  · intro c t typed
    rw [heap c t typed]
    exact state.heap c t typed
  · rw [links]
    exact state.links

/-- A write of contents of the written array's type keeps the heap typing. -/
theorem StateKinded.of_write {kinds : Nat → Option Ty} {hs hs' : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {root : Nat} {t : Ty} {xs : List Value}
    (typed : kinds root = some t) (contents : ContentsKinded kinds t xs)
    (heap : hs'.heap = hs.heap.set! root xs) (links : hs'.links = hs.links) :
    StateKinded kinds hs' env tenv := by
  refine ⟨?_, ?_, state.env⟩
  · intro c u typedC
    rw [heap]
    by_cases same : c = root
    · subst same
      rw [typed] at typedC
      cases Option.some.inj typedC
      refine ⟨xs, ?_, contents⟩
      simp [state.bound typed]
    · rw [HeapProof.lookup_set_other hs.heap root xs same]
      exact state.heap c u typedC
  · rw [links]
    exact state.links

/-- An allocation of contents of a source type extends the heap typing at
the new address. -/
theorem StateKinded.of_alloc {kinds : Nat → Option Ty} {hs hs' : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {t : Ty} {xs : List Value}
    (contents : ContentsKinded kinds t xs)
    (heap : hs'.heap = hs.heap.push xs) (links : hs'.links = hs.links) :
    ∃ kinds', StateKinded kinds' hs' env tenv ∧ (∀ c u, kinds c = some u → kinds' c = some u) ∧
      kinds' hs.heap.size = some t := by
  have untyped : kinds hs.heap.size = none := by
    cases found : kinds hs.heap.size with
    | none => rfl
    | some u =>
      have := state.bound found
      omega
  let kinds' : Nat → Option Ty := fun c => if c = hs.heap.size then some t else kinds c
  have mono : ∀ c u, kinds c = some u → kinds' c = some u := by
    intro c u typed
    have different : c ≠ hs.heap.size := by
      intro same
      rw [same, untyped] at typed
      cases typed
    simp [kinds', different, typed]
  refine ⟨kinds', ⟨?_, ?_, ?_⟩, mono, by simp [kinds']⟩
  · intro c u typed
    rw [heap]
    by_cases same : c = hs.heap.size
    · subst same
      have : u = t := by simpa [kinds'] using typed.symm
      subst this
      exact ⟨xs, by simp, contentsKinded_mono mono contents⟩
    · have old : kinds c = some u := by simpa [kinds', same] using typed
      obtain ⟨ys, lookup, contentsC⟩ := state.heap c u old
      refine ⟨ys, ?_, contentsKinded_mono mono contentsC⟩
      rw [Array.getElem?_push]
      simp [same, lookup]
  · intro v s front member
    rw [links] at member
    obtain ⟨u, viewTyped, sourceTyped⟩ := state.links v s front member
    exact ⟨u, mono v _ viewTyped, mono s _ sourceTyped⟩
  · intro x ty o w declared binding
    exact kinded_mono mono (state.env x ty o w declared binding)

theorem kindsAt_of_heap {hs hs' : InPlaceSemantics.State} {env : List (Var × Observation × Value)}
    {tenv : Env Ty} {type : Ty} {actual : Value} (kinds : KindsAt hs env tenv type actual)
    (heap : hs'.heap = hs.heap) (links : hs'.links = hs.links) : KindsAt hs' env tenv type actual := by
  obtain ⟨heapTyping, state, typed⟩ := kinds
  exact ⟨heapTyping, state.of_heap (fun _ _ _ => by rw [heap]) links, typed⟩

/-- Linked arrays have one type. -/
theorem StateKinded.connected_kind {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {a b : Nat}
    (connected : Ownership.LinkedWriteFrame.LinkConnected hs.links a b) : kinds a = kinds b := by
  induction connected with
  | refl => rfl
  | edge member =>
    obtain ⟨u, viewTyped, sourceTyped⟩ := state.links _ _ _ member
    rw [viewTyped, sourceTyped]
  | symm _ ih => exact ih.symm
  | trans _ _ ih₁ ih₂ => exact ih₁.trans ih₂

/-- A linked write of a list keeps the heap typing: every changed array is
linked to the written one, so it is a list of the same type, and its new
elements come from the stored list or from the old arrays of the component. -/
theorem StateKinded.of_linked_write {kinds : Nat → Option Ty} {hs hs' : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {root : Nat} {t : Ty} {stored : List Value}
    (typed : kinds root = some (.list t)) (storedTyped : ∀ x ∈ stored, Kinded kinds t x)
    (frame : ∀ a, ¬ Ownership.LinkedWriteFrame.LinkConnected hs.links root a → hs'.heap[a]? = hs.heap[a]?)
    (sizeEq : hs'.heap.size = hs.heap.size)
    (contents : Ownership.LinkedWriteRun.ComponentFrom hs.links root stored hs hs')
    (links : hs'.links = hs.links) : StateKinded kinds hs' env tenv := by
  refine ⟨?_, ?_, state.env⟩
  · intro c u typedC
    by_cases connected : Ownership.LinkedWriteFrame.LinkConnected hs.links root c
    · have same : kinds c = some (.list t) := (state.connected_kind connected).symm.trans typed
      rw [typedC] at same
      cases same
      have lt : c < hs'.heap.size := by rw [sizeEq]; exact state.bound typedC
      obtain ⟨xs, lookup⟩ : ∃ xs, hs'.heap[c]? = some xs := ⟨_, Array.getElem?_eq_getElem lt⟩
      refine ⟨xs, lookup, .list t xs fun x member => ?_⟩
      rcases contents c xs x lookup member connected with fromStored | ⟨d, zs, connectedD, lookupD, memberD⟩
      · exact storedTyped x fromStored
      · have typedD : kinds d = some (.list t) := (state.connected_kind connectedD).symm.trans typed
        exact state.list_contents typedD lookupD x memberD
    · rw [frame c connected]
      exact state.heap c u typedC
  · rw [links]
    exact state.links

/-- Everything a typed value reaches is allocated. -/
theorem StateKinded.reach_bound {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty}
    (state : StateKinded kinds hs env tenv) {t : Ty} {w : Value} {d : Nat}
    (typed : Kinded kinds t w) (reach : Reaches hs.heap w (.ref d)) : d < hs.heap.size := by
  generalize target : Value.ref d = goal at reach
  induction reach generalizing t with
  | refl v =>
    subst target
    cases typed with
    | list t c found => exact state.bound found
    | chain t c found => exact state.bound found
    | dict t c found => exact state.bound found
    | object ts c found => exact state.bound found
  | @element c xs x w lookup member _ ih =>
    cases typed with
    | list u c found => exact ih (state.list_contents found lookup x member) target
    | chain u c found => exact ih (state.chain_contents found lookup x member) target
    | dict u c found =>
      obtain ⟨k, v, rfl, typedV⟩ := state.dict_contents found lookup x member
      refine ih (t := .record [.int, u]) (.record _ _ rfl ?_) target
      intro i t' w' ts_i ws_i
      cases i with
      | zero =>
        simp at ts_i ws_i
        subst ts_i
        subst ws_i
        exact .int k
      | succ i =>
        cases i with
        | zero =>
          simp at ts_i ws_i
          subst ts_i
          subst ws_i
          exact typedV
        | succ i => simp at ts_i
    | object ts c found =>
      exact ih (state.object_contents found lookup x member) target
  | @field xs x w member _ ih =>
    cases typed with
    | record ts ws lengths fields =>
      obtain ⟨i, ws_i⟩ := List.mem_iff_getElem?.mp member
      obtain ⟨t', ts_i⟩ : ∃ t', ts[i]? = some t' := by
        have lt : i < ts.length := by
          rw [← lengths]
          exact (List.getElem?_eq_some_iff.mp ws_i).1
        exact ⟨ts[i], List.getElem?_eq_getElem lt⟩
      exact ih (fields i t' x ts_i ws_i) target
    | ok error success w' typedW =>
      simp only [List.mem_cons, List.not_mem_nil, or_false] at member
      rcases member with rfl | rfl | rfl
      · exact ih (.int 1) target
      · exact ih (.int 0) target
      · exact ih typedW target
    | err error success w' typedW =>
      simp only [List.mem_cons, List.not_mem_nil, or_false] at member
      rcases member with rfl | rfl | rfl
      · exact ih (.int 0) target
      · exact ih typedW target
      · exact ih (.int 0) target
  | capture member _ ih => cases typed

/-- A projection along a field path has the type at that path. -/
theorem kinded_fieldProject {kinds : Nat → Option Ty} {heap : Heap} :
    ∀ {p : Path} {ty t : Ty} {w w' : Value}, Kinded kinds ty w →
      Ownership.FlatFragment.Fields.fieldTyAt ty p = some t → projectHeap heap w p = some w' →
        Kinded kinds t w' := by
  intro p
  induction p with
  | nil =>
    intro ty t w w' typed at_p valuePath
    simp only [Ownership.FlatFragment.Fields.fieldTyAt, Option.some.injEq] at at_p
    simp only [projectHeap, Option.some.injEq] at valuePath
    subst at_p
    subst valuePath
    exact typed
  | cons step rest ih =>
    intro ty t w w' typed at_p valuePath
    cases step with
    | field i =>
      cases ty with
      | record ts =>
        obtain ⟨ws, rfl, _, fields⟩ := kinded_record_inv typed
        simp only [Ownership.FlatFragment.Fields.fieldTyAt] at at_p
        cases foundT : ts[i]? with
        | none => rw [foundT] at at_p; cases at_p
        | some ti =>
          rw [foundT] at at_p
          simp only [projectHeap] at valuePath
          cases foundW : ws[i]? with
          | none => rw [foundW] at valuePath; cases valuePath
          | some wi =>
            rw [foundW] at valuePath
            exact ih (fields i ti wi foundT foundW) at_p valuePath
      | _ => simp [Ownership.FlatFragment.Fields.fieldTyAt] at at_p
    | _ => cases ty <;> simp [Ownership.FlatFragment.Fields.fieldTyAt] at at_p

/-- The element step of an observation projection reads only a one-slot list
whose slot is a record. -/
theorem projectObs_element_inv {items : List Observation} {rest : Path} {o' : Observation}
    (projected : projectObs (.list items) (.element :: rest) = some o') :
    ∃ xs, items = [.record xs] ∧ projectObs (.record xs) rest = some o' := by
  match items, projected with
  | [.record xs], projected => exact ⟨xs, rfl, by simpa only [projectObs] using projected⟩
  | [], projected => simp [projectObs] at projected
  | [.int _], projected => simp [projectObs] at projected
  | [.list _], projected => simp [projectObs] at projected
  | [.closure _ _], projected => simp [projectObs] at projected
  | _ :: _ :: _, projected => simp [projectObs] at projected

/-- The element step of a heap projection reads only a one-slot array whose
slot is a record. -/
theorem projectHeap_element_inv {heap : Heap} {c : Nat} {rest : Path} {w' : Value}
    (projected : projectHeap heap (.ref c) (.element :: rest) = some w') :
    ∃ xs, heap[c]? = some [.record xs] ∧ projectHeap heap (.record xs) rest = some w' := by
  simp only [projectHeap] at projected
  split at projected
  · rename_i xs found
    exact ⟨xs, found, projected⟩
  · cases projected

theorem projectHeap_element {heap : Heap} {c : Nat} {rest : Path} {xs : List Value}
    (found : heap[c]? = some [.record xs]) :
    projectHeap heap (.ref c) (.element :: rest) = projectHeap heap (.record xs) rest := by
  simp only [projectHeap, found]

/-- A projection along a use path has the type at that path; the slot of a
record object has its record type (#316). -/
theorem kinded_project {kinds : Nat → Option Ty} {hs : InPlaceSemantics.State}
    {env : List (Var × Observation × Value)} {tenv : Env Ty} (state : StateKinded kinds hs env tenv) :
    ∀ {p : Path} {ty t : Ty} {w w' : Value}, Kinded kinds ty w →
      Ownership.FlatFragment.Fields.tyAt ty p = some t → projectHeap hs.heap w p = some w' →
        Kinded kinds t w' := by
  intro p
  induction p with
  | nil =>
    intro ty t w w' typed at_p valuePath
    simp only [Ownership.FlatFragment.Fields.tyAt, Option.some.injEq] at at_p
    simp only [projectHeap, Option.some.injEq] at valuePath
    subst at_p
    subst valuePath
    exact typed
  | cons step rest ih =>
    intro ty t w w' typed at_p valuePath
    cases step with
    | field i =>
      cases ty with
      | record ts =>
        obtain ⟨ws, rfl, _, fields⟩ := kinded_record_inv typed
        simp only [Ownership.FlatFragment.Fields.tyAt] at at_p
        cases foundT : ts[i]? with
        | none => rw [foundT] at at_p; cases at_p
        | some ti =>
          rw [foundT] at at_p
          simp only [projectHeap] at valuePath
          cases foundW : ws[i]? with
          | none => rw [foundW] at valuePath; cases valuePath
          | some wi =>
            rw [foundW] at valuePath
            exact ih (fields i ti wi foundT foundW) at_p valuePath
      | _ => simp [Ownership.FlatFragment.Fields.tyAt] at at_p
    | element =>
      cases ty with
      | object ts =>
        obtain ⟨c, rfl, found⟩ := kinded_object_inv typed
        obtain ⟨x, slot, typedX⟩ := state.object_slot found
        obtain ⟨xs, rfl, _, _⟩ := kinded_record_inv typedX
        simp only [Ownership.FlatFragment.Fields.tyAt] at at_p
        rw [projectHeap_element slot] at valuePath
        exact kinded_fieldProject typedX at_p valuePath
      | _ => simp [Ownership.FlatFragment.Fields.tyAt] at at_p
    | _ => cases ty <;> simp [Ownership.FlatFragment.Fields.tyAt] at at_p

/-- An integer primitive types only at two `Int` operands, and its result is `Int`. -/
theorem primType_scalar_success {op : Prim} {tyA tyB type : Ty} (sop : Ownership.FlatFragment.Support.ScalarOp op)
    (flatA : FlatType tyA) (flatB : FlatType tyB) (run : primType op [tyA, tyB] = .ok type) :
    tyA = .int ∧ tyB = .int ∧ type = .int := by
  cases sop <;> cases flatA <;> cases flatB <;> simp [primType] at run <;>
    first
    | (change Except.ok Ty.int = Except.ok type at run; cases Except.ok.inj run; exact ⟨rfl, rfl, rfl⟩)
    | (cases run; exact ⟨rfl, rfl, rfl⟩)

end Ownership.FlatFragment.State

namespace Ownership.FlatFragment.HeapPreservation

open InPlaceSemantics HeapProof Soundness

/-- The runtime shape of a flat binding: an integer, an allocated array whose
elements have the element type's shape (a list of flat values, slice 2b of
#522), an allocated array of integers (a chain), a record of such values, or a
result as both interpreters build it: a success `[1, 0, x]` or an error
`[0, x, 0]` over such a payload. The shape is a finite derivation, so no array
reaches itself through it. It says what the binding's own arrays hold; it says
nothing about the other arrays of the heap. Since slice 2b the relation keeps
it as a clause (`FlatInvariant.bindingsTyped`): a typed observation leaves a result's
dead slot open, so the shape of a list's elements cannot be read off the
types. -/
inductive AllocatedFlatValue (heap : Heap) : Value → Ty → Prop where
  | int (integer : Int) : AllocatedFlatValue heap (.int integer) .int
  | list (root : Nat) (ws : List Value) (t : Ty) : heap[root]? = some ws →
      (∀ w ∈ ws, AllocatedFlatValue heap w t) → AllocatedFlatValue heap (.ref root) (.list t)
  | chain (root : Nat) (integers : List Int) : heap[root]? = some (integers.map Value.int) →
      AllocatedFlatValue heap (.ref root) (.chain .int)
  | record (ws : List Value) (ts : List Ty) : ws.length = ts.length →
      (∀ (i : Nat) (w : Value) (t : Ty), ws[i]? = some w → ts[i]? = some t →
        AllocatedFlatValue heap w t) →
      AllocatedFlatValue heap (.record ws) (.record ts)
  | ok (error success : Ty) (w : Value) : AllocatedFlatValue heap w success →
      AllocatedFlatValue heap (.record [.int 1, .int 0, w]) (.result error success)
  | err (error success : Ty) (w : Value) : AllocatedFlatValue heap w error →
      AllocatedFlatValue heap (.record [.int 0, w, .int 0]) (.result error success)
  /-- A record object (#316): an allocated array of one slot, the record. -/
  | object (root : Nat) (w : Value) (ts : List Ty) : heap[root]? = some [w] →
      AllocatedFlatValue heap w (.record ts) → AllocatedFlatValue heap (.ref root) (.object ts)

end Ownership.FlatFragment.HeapPreservation

namespace Ownership.FlatFragment.State

open InPlaceSemantics HeapProof Soundness

/-- Every address in the naming already exists in the concrete heap. This
local definition has the same statement as the checked naming support.
 -/
def NamingBound (gamma : Naming) (bound : Nat) : Prop :=
  ∀ origin address, address ∈ gamma origin → address < bound

def emptyNaming : Naming := fun _ => []

theorem emptyNaming_separating : Separating emptyNaming := by
  intro first second different address member
  simp [emptyNaming] at member

theorem emptyNaming_bound (bound : Nat) : NamingBound emptyNaming bound := by
  intro origin address member
  simp [emptyNaming] at member

/-- The fields `keep` marks, in order: the fields of a record object that a
live use reads through its slot (#316). -/
def selectFields {α : Type} : List Bool → List α → List α
  | b :: bs, x :: xs => if b then x :: selectFields bs xs else selectFields bs xs
  | _, _ => []

theorem selectFields_sublist {α : Type} : ∀ (keep : List Bool) (xs : List α),
    (selectFields keep xs).Sublist xs
  | b :: bs, x :: xs => by
    unfold selectFields
    split
    · exact (selectFields_sublist bs xs).cons₂ x
    · exact (selectFields_sublist bs xs).cons x
  | [], _ => by simp [selectFields]
  | _ :: _, [] => by simp [selectFields]

theorem mem_selectFields {α : Type} : ∀ {keep : List Bool} {xs : List α} {v : α},
    v ∈ selectFields keep xs → ∃ g : Nat, keep[g]? = some true ∧ xs[g]? = some v
  | b :: bs, x :: xs, v, member => by
    unfold selectFields at member
    split at member
    · rename_i kept
      rcases List.mem_cons.mp member with rfl | later
      · exact ⟨0, by simp [kept], rfl⟩
      · obtain ⟨g, keepG, xsG⟩ := mem_selectFields later
        exact ⟨g + 1, by simpa using keepG, by simpa using xsG⟩
    · obtain ⟨g, keepG, xsG⟩ := mem_selectFields member
      exact ⟨g + 1, by simpa using keepG, by simpa using xsG⟩
  | [], _, _, member => by simp [selectFields] at member
  | _ :: _, [], _, member => by simp [selectFields] at member

/-! #### The fields of an update (`assignFields`, #316) -/

theorem foldl_set_length {α : Type} : ∀ (l : List (Nat × α)) (xs : List α),
    (l.foldl (fun ys (p : Nat × α) => ys.set p.1 p.2) xs).length = xs.length
  | [], _ => rfl
  | (f, v) :: l, xs => by
    simp only [List.foldl_cons]
    rw [foldl_set_length l (xs.set f v), List.length_set]

theorem assignFields_length {α : Type} (xs : List α) (fs : List Nat) (vs : List α) :
    (assignFields xs fs vs).length = xs.length := by
  unfold assignFields
  exact foldl_set_length _ xs

theorem foldl_set_forall {α : Type} {P : Nat → α → Prop} : ∀ (l : List (Nat × α)) (xs : List α),
    (∀ i x, xs[i]? = some x → P i x) → (∀ p ∈ l, P p.1 p.2) →
      ∀ i x, (l.foldl (fun ys (p : Nat × α) => ys.set p.1 p.2) xs)[i]? = some x → P i x
  | [], xs, old, _ => fun i x found => old i x found
  | (f, v) :: l, xs, old, new => by
    simp only [List.foldl_cons]
    apply foldl_set_forall l (xs.set f v) _ (fun p member => new p (List.mem_cons_of_mem _ member))
    intro i x found
    rw [List.getElem?_set] at found
    split at found
    · rename_i same
      subst same
      split at found
      · cases found
        exact new (f, v) (by simp)
      · cases found
    · exact old i x found

/-- Every field of an update's result is an old field or a new value. -/
theorem assignFields_forall {α : Type} {P : Nat → α → Prop} {xs : List α} {fs : List Nat} {vs : List α}
    (old : ∀ i x, xs[i]? = some x → P i x) (new : ∀ f v, (f, v) ∈ fs.zip vs → P f v) :
    ∀ i x, (assignFields xs fs vs)[i]? = some x → P i x := by
  unfold assignFields
  exact foldl_set_forall _ xs old (fun p member => new p.1 p.2 member)

/-- An update keeps the fields it does not write. -/
theorem assignFields_kept {α : Type} {xs : List α} {fs : List Nat} {vs : List α} {i : Nat}
    (kept : i ∉ fs) : (assignFields xs fs vs)[i]? = xs[i]? := by
  unfold assignFields
  have general : ∀ (l : List (Nat × α)) (ys : List α), (∀ p ∈ l, p.1 ≠ i) →
      (l.foldl (fun ys (p : Nat × α) => ys.set p.1 p.2) ys)[i]? = ys[i]? := by
    intro l
    induction l with
    | nil => intro ys _; rfl
    | cons p l ih =>
      intro ys apart
      simp only [List.foldl_cons]
      rw [ih _ (fun q member => apart q (List.mem_cons_of_mem _ member)),
        List.getElem?_set_ne (apart p (by simp))]
  exact general _ xs (fun p member same => kept (same ▸ (List.of_mem_zip member).1))

/-- Two lists updated at the same fields with related values are related at
every field: a field either keeps its old values, which must be related, or
holds the values of its last write. -/
theorem foldl_set_rel {α β : Type} {R : α → β → Prop} :
    ∀ (fs : List Nat) (as : List α) (bs : List β) (xs : List α) (ys : List β) (G : Nat → Prop),
      as.length = fs.length → bs.length = fs.length →
      (∀ i x y, xs[i]? = some x → ys[i]? = some y → G i → R x y) →
      (∀ (j : Nat) a b, as[j]? = some a → bs[j]? = some b → R a b) →
      ∀ i x y, ((fs.zip as).foldl (fun zs (p : Nat × α) => zs.set p.1 p.2) xs)[i]? = some x →
        ((fs.zip bs).foldl (fun zs (p : Nat × β) => zs.set p.1 p.2) ys)[i]? = some y →
        (G i ∨ i ∈ fs) → R x y
  | [], as, bs, xs, ys, G, la, lb, old, _ => by
    intro i x y fx fy good
    rcases good with g | m
    · exact old i x y fx fy g
    · simp at m
  | f :: fs, a :: as, b :: bs, xs, ys, G, la, lb, old, new => by
    intro i x y fx fy good
    simp only [List.zip_cons_cons, List.foldl_cons] at fx fy
    refine foldl_set_rel fs as bs (xs.set f a) (ys.set f b) (fun i => G i ∨ i = f)
      (by simpa using la) (by simpa using lb) ?_ (fun j a' b' ha hb => new (j + 1) a' b' (by simpa using ha)
        (by simpa using hb)) i x y fx fy ?_
    · intro k x' y' hx hy gk
      rw [List.getElem?_set] at hx hy
      by_cases same : f = k
      · subst same
        simp only [if_true] at hx hy
        split at hx
        · split at hy
          · cases hx; cases hy
            exact new 0 a b rfl rfl
          · cases hy
        · cases hx
      · simp only [same, if_false] at hx hy
        rcases gk with g | e
        · exact old k x' y' hx hy g
        · exact absurd e.symm same
    · rcases good with g | m
      · exact Or.inl (Or.inl g)
      · rcases List.mem_cons.mp m with e | later
        · exact Or.inl (Or.inr e)
        · exact Or.inr later
  | _ :: _, [], _, _, _, _, la, _, _, _ => by simp at la
  | _ :: _, _ :: _, [], _, _, _, _, lb, _, _ => by simp at lb

/-- The pointwise relation of two updates of related lists by related
values at the same fields. -/
theorem assignFields_rel {α β : Type} {R : α → β → Prop} {xs : List α} {ys : List β} {fs : List Nat}
    {as : List α} {bs : List β} (la : as.length = fs.length) (lb : bs.length = fs.length)
    (old : ∀ (i : Nat) x y, i ∉ fs → xs[i]? = some x → ys[i]? = some y → R x y)
    (new : ∀ (j : Nat) a b, as[j]? = some a → bs[j]? = some b → R a b) :
    ∀ (i : Nat) x y, (assignFields xs fs as)[i]? = some x → (assignFields ys fs bs)[i]? = some y → R x y := by
  intro i x y fx fy
  unfold assignFields at fx fy
  by_cases m : i ∈ fs
  · exact foldl_set_rel fs as bs xs ys (fun i => i ∉ fs) la lb (fun i x y hx hy g => old i x y g hx hy) new
      i x y fx fy (Or.inr m)
  · exact foldl_set_rel fs as bs xs ys (fun i => i ∉ fs) la lb (fun i x y hx hy g => old i x y g hx hy) new
      i x y fx fy (Or.inl m)

theorem foldl_set_source {α : Type} : ∀ (fs : List Nat) (as : List α) (xs : List α),
    as.length = fs.length →
    ∀ i x, ((fs.zip as).foldl (fun zs (p : Nat × α) => zs.set p.1 p.2) xs)[i]? = some x →
      (i ∉ fs ∧ xs[i]? = some x) ∨
      ∃ j : Nat, fs[j]? = some i ∧ as[j]? = some x ∧ ∀ j' : Nat, j < j' → fs[j']? ≠ some i
  | [], as, xs, _ => by
    intro i x found
    exact Or.inl ⟨by simp, found⟩
  | f :: fs, a :: as, xs, la => by
    intro i x found
    simp only [List.zip_cons_cons, List.foldl_cons] at found
    rcases foldl_set_source fs as (xs.set f a) (by simpa using la) i x found with ⟨notIn, old⟩ | ⟨j, fs_j, as_j, last⟩
    · rw [List.getElem?_set] at old
      by_cases same : f = i
      · subst same
        simp only [if_true] at old
        split at old
        · cases old
          refine Or.inr ⟨0, rfl, rfl, fun j' pos => ?_⟩
          cases j' with
          | zero => omega
          | succ j' =>
            simp only [List.getElem?_cons_succ]
            intro member
            exact notIn (List.mem_of_getElem? member)
        · cases old
      · simp only [same, if_false] at old
        exact Or.inl ⟨by simp [Ne.symm same, notIn], old⟩
    · refine Or.inr ⟨j + 1, by simpa using fs_j, by simpa using as_j, fun j' pos => ?_⟩
      cases j' with
      | zero => omega
      | succ j' => simpa using last j' (by omega)
  | _ :: _, [], _, la => by simp at la

/-- Each field of an update's result is an old field it keeps, or the new
value of its last write. -/
theorem assignFields_source {α : Type} {xs : List α} {fs : List Nat} {as : List α}
    (la : as.length = fs.length) :
    ∀ i x, (assignFields xs fs as)[i]? = some x →
      (i ∉ fs ∧ xs[i]? = some x) ∨
      ∃ j : Nat, fs[j]? = some i ∧ as[j]? = some x ∧ ∀ j' : Nat, j < j' → fs[j']? ≠ some i := by
  unfold assignFields
  exact foldl_set_source fs as xs la

/-- Two last writes of one field are the same write. -/
theorem last_write_unique {fs : List Nat} {i j j' : Nat}
    (at_j : fs[j]? = some i) (last : ∀ k, j < k → fs[k]? ≠ some i)
    (at_j' : fs[j']? = some i) (last' : ∀ k, j' < k → fs[k]? ≠ some i) : j = j' := by
  rcases Nat.lt_trichotomy j j' with lt | eq | gt
  · exact absurd at_j' (last j' lt)
  · exact eq
  · exact absurd at_j (last' j gt)

/-- The mask that selects one field. -/
theorem selectFields_single {α : Type} : ∀ (i : Nat) (xs : List α) (x : α), xs[i]? = some x →
    selectFields (List.replicate i false ++ [true]) xs = [x]
  | 0, y :: ys, x, at_i => by
    simp at at_i
    subst at_i
    simp [selectFields]
  | i + 1, y :: ys, x, at_i => by
    simp only [List.replicate_succ, List.cons_append, selectFields, Bool.false_eq_true, if_false]
    exact selectFields_single i ys x (by simpa using at_i)
  | _, [], _, at_i => by simp at at_i

theorem replicate_false_append_get {i g : Nat} {rest : List Bool} :
    (List.replicate i false ++ rest)[g]? = if g < i then some false else rest[g - i]? := by
  rw [List.getElem?_append]
  by_cases lt : g < i
  · simp [lt, List.getElem?_replicate]
  · simp [lt]

theorem selectFields_single_mem {i g : Nat} (kept : (List.replicate i false ++ [true])[g]? = some true) :
    g = i := by
  rw [replicate_false_append_get] at kept
  by_cases lt : g < i
  · simp [lt] at kept
  · simp only [lt, if_false] at kept
    cases h : g - i with
    | zero => omega
    | succ k => rw [h] at kept; simp at kept

/-- The mask that selects two fields. -/
theorem selectFields_pair {α : Type} : ∀ (i d : Nat) (xs : List α) (x y : α), xs[i]? = some x →
    xs[i + 1 + d]? = some y →
    selectFields (List.replicate i false ++ [true] ++ List.replicate d false ++ [true]) xs = [x, y]
  | 0, d, z :: zs, x, y, at_i, at_j => by
    simp at at_i
    subst at_i
    simp only [List.replicate_zero, List.nil_append, List.cons_append, selectFields, if_true]
    congr 1
    have := selectFields_single d zs y (by simpa [Nat.add_comm] using at_j)
    simpa using this
  | i + 1, d, z :: zs, x, y, at_i, at_j => by
    simp only [List.replicate_succ, List.cons_append, selectFields, Bool.false_eq_true, if_false]
    have := selectFields_pair i d zs x y (by simpa using at_i) (by
      have : i + 1 + 1 + d = (i + 1 + d) + 1 := by omega
      rw [this] at at_j
      simpa using at_j)
    simpa using this
  | _, _, [], _, _, at_i, _ => by simp at at_i

theorem selectFields_pair_mem {i d g : Nat}
    (kept : (List.replicate i false ++ [true] ++ List.replicate d false ++ [true])[g]? = some true) :
    g = i ∨ g = i + 1 + d := by
  simp only [List.append_assoc] at kept
  rw [replicate_false_append_get] at kept
  by_cases lt : g < i
  · simp [lt] at kept
  · simp only [lt, if_false] at kept
    cases h : g - i with
    | zero => exact Or.inl (by omega)
    | succ k =>
      rw [h] at kept
      simp only [List.singleton_append, List.getElem?_cons_succ] at kept
      rw [replicate_false_append_get] at kept
      by_cases lt' : k < d
      · simp [lt'] at kept
      · simp only [lt', if_false] at kept
        cases h' : k - d with
        | zero => exact Or.inr (by omega)
        | succ m => rw [h'] at kept; simp at kept

/-- The type environment supplies a type for every runtime lookup, including
dead bindings. The value observation retains its type, but its contents need
not match the current heap contents. `ValueTyped` supplies a complete finite
expansion of the current runtime value and therefore excludes dangling roots.
Every live use has the runtime shape of its type (`bindingsTyped`, per live
path since slice 2b of #522): the shape of a list's elements is kept, since a
typed observation leaves a result's dead slot open. A dead alias of a written
array keeps no type, only the bound of its arrays (`bindingsBounded`).

The abstract and type environments have the exact runtime key sequence.
Their descriptions have the flat shapes that real primitive inference needs
(`FlatAbstract`, which admits the bottom of dead code). The relation makes
no claim about the contents of an array that no binding holds, except through
the observer witness: what a binding's arrays hold comes from its type, through
`bindingsTyped` (an integer list holds integers). The permanent
observer witness covers the complete current observer list at the runtime's
actual observation depth. Every binding's result tags agree with its
abstract (`ResultTags`), which also excludes a bottom where a value is, its
chain tags agree with its observation (`ChainTags`: a chain described with a
bottom element is empty). The `deepTags` clause carries result and chain tags
for array elements at each live path, through nested arrays and active result
payloads. Every live use is a typed path of its binding,
so a projection of a live use never enters a result.

The heap clauses read a binding through its representation (#1796): its type
`entryType t`, in which a dictionary is a list of entry records `[Int, t]`,
and its abstract `entryAbstract declarations t a`, in which the value is field
1 of the entry. A type with no dictionary is its own representation, so these
clauses say for it what they said before.

Record objects (#316). A live use reads a field of an object through the
object's one slot (`projectHeap`), so its route is the object's array. Every
binding's observation has its type (`observationsTyped`): an update that
writes every field does not use its base, and the value interpreter still
matches the base's shape. The certificate of an object at a field path of a
binding holds over the fields that a live use reads through its slot
(`objectsCertified`): after an update, the old holder's written fields hold
new values, so the whole old object is not described, but the fields it keeps
are the old ones, and an update keeps the old certificate over them. Every
live path carries the result and chain tags of its value (`liveTags`): a
field read through a slot needs them, and the object is not live itself.
-/
structure FlatInvariant (declarations : List Decl)
    (vs : ValueSemantics.State) (hs : InPlaceSemantics.State)
    (env : List (Var × Observation × Value)) (live : Live)
    (aenv : Env Abstract) (tenv : Env Ty)
    (escapes : List Origin) (gamma : Naming) : Prop where
  toInvariant : Invariant declarations vs hs env live aenv tenv escapes gamma
  linkClosed : Ownership.LinkClauses.LinkClosed hs.links gamma
  abstractKeys : env.map Prod.fst = aenv.map Prod.fst
  typeKeys : env.map Prod.fst = tenv.map Prod.fst
  types : ∀ x ty, tenv.lookup x = some ty → FlatType ty
  abstractShapes : ∀ x ty abstract,
    tenv.lookup x = some ty → aenv.lookup x = some abstract →
      FlatAbstract ty abstract
  bindingsTyped : ∀ x p, (x, p) ∈ live → ∀ observation actual ty,
    env.lookup x = some (observation, actual) → tenv.lookup x = some ty →
      ∃ t observation' actual',
        Ownership.FlatFragment.Fields.tyAt ty p = some t ∧
        projectObs observation p = some observation' ∧ projectHeap hs.heap actual p = some actual' ∧
        obsTyped declarations observation' t = true ∧
        Ownership.FlatFragment.HeapPreservation.AllocatedFlatValue hs.heap actual' (entryType t)
  deepTags : ∀ x p, (x, p) ∈ live → ∀ observation actual ty abstract t actual',
    env.lookup x = some (observation, actual) → tenv.lookup x = some ty →
    aenv.lookup x = some abstract → Ownership.FlatFragment.Fields.tyAt ty p = some t →
    projectHeap hs.heap actual p = some actual' →
      TagsDeep hs.heap (entryType t) (entryAbstract declarations t (abstract.atPath p)) actual'
  bindingsBounded : ∀ x observation actual,
    env.lookup x = some (observation, actual) →
      ∀ c, Reaches hs.heap actual (.ref c) → c < hs.heap.size
  tags : ∀ x ty abstract observation actual,
    tenv.lookup x = some ty → aenv.lookup x = some abstract →
      env.lookup x = some (observation, actual) →
        ResultTags (entryType ty) (entryAbstract declarations ty abstract) actual
  chains : ∀ x ty abstract observation actual,
    tenv.lookup x = some ty → aenv.lookup x = some abstract →
      env.lookup x = some (observation, actual) →
        ChainTags (entryType ty) (entryAbstract declarations ty abstract) observation
  liveTyped : ∀ x p ty, (x, p) ∈ live → tenv.lookup x = some ty →
    ∃ t, Ownership.FlatFragment.Fields.tyAt ty p = some t
  namingBound : NamingBound gamma hs.heap.size
  observers : ∃ footprint,
    RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint
  heapKinds : ∃ kinds, StateKinded kinds hs env tenv
  observationsTyped : ∀ x ty o w, tenv.lookup x = some ty → env.lookup x = some (o, w) →
    obsTyped declarations o ty = true
  objectsCertified : ∀ x o w a q c roots e ex ws, env.lookup x = some (o, w) → aenv.lookup x = some a →
    (∀ s ∈ q, ∃ i, s = Step.field i) → projectHeap hs.heap w q = some (.ref c) →
    a.atPath q = .list roots e ex → hs.heap[c]? = some [.record ws] →
    ∀ keep : List Bool, (∀ g, keep[g]? = some true → (x, q ++ [.element, .field g]) ∈ live) →
      ∀ n os fps, RepresentsMany hs.heap n (selectFields keep ws) os fps →
        (ex.deep = true → (c :: fps).Nodup) ∧
        (ex.spine = true → ∀ v ∈ selectFields keep ws, ∀ p d, containerPath p = true →
          ArrayAt hs.heap v p d → (c :: fps).count d = 1)
  liveTags : ∀ x p, (x, p) ∈ live → ∀ observation actual ty abstract t observation' actual',
    env.lookup x = some (observation, actual) → tenv.lookup x = some ty → aenv.lookup x = some abstract →
    Ownership.FlatFragment.Fields.tyAt ty p = some t → projectObs observation p = some observation' →
    projectHeap hs.heap actual p = some actual' →
      ResultTags (entryType t) (entryAbstract declarations t (abstract.atPath p)) actual' ∧
      ChainTags (entryType t) (entryAbstract declarations t (abstract.atPath p)) observation'

/-! The audit refuses `extends`, so the prefix invariant is a plain field.
These wrappers keep every projection of the parent available by dot notation. -/

theorem FlatInvariant.reads {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) : vs.reads = hs.reads := inv.toInvariant.reads

theorem FlatInvariant.external {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) : vs.externalReads = hs.externalReads :=
  inv.toInvariant.external

theorem FlatInvariant.fuel {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) : vs.fuel = hs.fuel := inv.toInvariant.fuel

theorem FlatInvariant.keptSize {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) : vs.kept.size = hs.kept.size := inv.toInvariant.keptSize

theorem FlatInvariant.kept {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ (i : Nat) o w, vs.kept[i]? = some o → hs.kept[i]? = some w → Corresponds hs.heap o w :=
  inv.toInvariant.kept

theorem FlatInvariant.keptEscaped {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ k ∈ hs.kept.toList, ∀ c, Reaches hs.heap k (.ref c) → ∀ g, c ∈ gamma g → Escaped escapes g :=
  inv.toInvariant.keptEscaped

theorem FlatInvariant.bindings {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x p, (x, p) ∈ live → ∀ o w, env.lookup x = some (o, w) →
      ∃ o' w', projectObs o p = some o' ∧ projectHeap hs.heap w p = some w' ∧ Corresponds hs.heap o' w' :=
  inv.toInvariant.bindings

theorem FlatInvariant.named {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x o w a, env.lookup x = some (o, w) → aenv.lookup x = some a →
      ∀ q c, immutablePath q = true → ArrayAt hs.heap w q c → named gamma (a.cellsAt q) c :=
  inv.toInvariant.named

theorem FlatInvariant.separating {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) : Separating gamma := inv.toInvariant.separating

/-- A step that keeps the heap and the links keeps the heap typing; the
result has its type under it. -/
theorem FlatInvariant.kindsAt_of {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    {hs' : InPlaceSemantics.State} (heap : hs'.heap = hs.heap) (links : hs'.links = hs.links)
    {type : Ty} {actual : Value}
    (typed : ∀ kinds, StateKinded kinds hs env tenv → Kinded kinds type actual) :
    KindsAt hs' env tenv type actual := by
  obtain ⟨kinds, state⟩ := inv.heapKinds
  exact ⟨kinds, state.of_heap (fun _ _ _ => by rw [heap]) links, typed kinds state⟩

/-- The current heap value of every runtime reference remains allocated.
The binding need not occur in the live-use set. -/
theorem FlatInvariant.binding_allocated
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (binding : env.lookup x = some (observation, .ref address)) :
    address < hs.heap.size := by
  exact inv.bindingsBounded x observation (.ref address) binding address (.refl _)

/-- The complete observer witness gives the executable snapshot equation.
No empty-observer premise enters this theorem. -/
theorem FlatInvariant.observer_snapshots
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    hs.kept.toList.mapM (snapshot hs.heap observationDepth) = .ok vs.kept.toList := by
  obtain ⟨footprint, represented⟩ := inv.observers
  exact snapshots_of_represents represented

/-- All cells in the complete observer footprint remain allocated. -/
theorem FlatInvariant.observer_footprint_bound
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∃ footprint,
      RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint ∧
      ∀ address ∈ footprint, address < hs.heap.size := by
  obtain ⟨footprint, represented⟩ := inv.observers
  exact ⟨footprint, represented, representsMany_bound represented⟩

/-- Both runtimes start a closed program with only its fuel field set.
Their default fields supply empty heaps, observers, links, and environments.
The live-use set and the recorded escape set remain arbitrary here. -/
theorem flatInvariant_initial (declarations : List Decl) (fuel : Nat)
    (live : Live) (escapes : List Origin) :
    FlatInvariant declarations
      ({ fuel } : ValueSemantics.State) ({ fuel } : InPlaceSemantics.State)
      [] live [] [] escapes emptyNaming := by
  refine {
    toInvariant := invariant_initial declarations fuel live [] escapes emptyNaming emptyNaming_separating
    linkClosed := Ownership.LinkClauses.linkClosed_of_empty _ _ rfl
    abstractKeys := rfl
    typeKeys := rfl
    types := ?_
    abstractShapes := ?_
    bindingsTyped := ?_
    deepTags := by intro x p use o w ty a t w' binding; simp at binding
    bindingsBounded := ?_
    tags := ?_
    chains := ?_
    liveTyped := ?_
    namingBound := emptyNaming_bound 0
    observers := ⟨[], RepresentsMany.nil⟩
    heapKinds := ⟨fun _ => none, ⟨(by intro c t typed; simp at typed),
      (by intro v s front member; simp at member), (by intro x ty o w declared; simp at declared)⟩⟩
    observationsTyped := by intro x ty o w declared; simp at declared
    objectsCertified := by intro x o w a q c roots e ex ws binding; simp at binding
    liveTags := by intro x p _ o w ty a t o' w' binding; simp at binding
  }
  · intro x ty present
    simp at present
  · intro x ty abstract present
    simp at present
  · intro x p _ observation actual ty present
    simp at present
  · intro x observation actual present
    simp at present
  · intro x ty abstract observation actual present
    simp at present
  · intro x ty abstract observation actual present
    simp at present
  · intro x p ty _ present
    simp at present

/-- Initial emptiness follows from the runtime state constructors. It is
not a restriction on the later heaps or observers of `FlatInvariant`. -/
theorem closed_initial_configuration (declarations : List Decl) (fuel : Nat)
    (live : Live) (escapes : List Origin) :
    let vs : ValueSemantics.State := { fuel }
    let hs : InPlaceSemantics.State := { fuel }
    FlatInvariant declarations vs hs [] live [] [] escapes emptyNaming ∧
      hs.heap = #[] ∧ hs.kept = #[] ∧ vs.kept = #[] := by
  exact ⟨flatInvariant_initial declarations fuel live escapes, rfl, rfl, rfl⟩

end Ownership.FlatFragment.State

/-! root-name extraction for the actual demand frame.
The prefix invariant names every binding, including dead aliases.
These lemmas recover the exact primitive root row after its real union fold.
They assume no separately checked permission predicate. -/

namespace Ownership.FlatFragment.NamingFacts

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.State Ownership.FlatFragment.Description

theorem mem_union_cases [BEq α] (first second : List α) (value : α)
    (member : value ∈ union first second) : value ∈ first ∨ value ∈ second := by
  induction second generalizing first with
  | nil => exact Or.inl member
  | cons head tail ih =>
    change value ∈ union (if first.contains head then first else first ++ [head]) tail at member
    rcases ih _ member with previous | later
    · by_cases present : first.contains head = true
      · rw [if_pos present] at previous
        exact Or.inl previous
      · rw [if_neg present] at previous
        rcases List.mem_append.mp previous with old | added
        · exact Or.inl old
        · exact Or.inr (List.mem_cons.mpr (Or.inl (by simpa using added)))
    · exact Or.inr (List.mem_cons_of_mem head later)

theorem named_union_nil
    (names : named gamma (union [] roots) root) : named gamma roots root := by
  obtain ⟨origin, member, address⟩ := names
  rcases mem_union_cases [] roots origin member with impossible | original
  · simp at impossible
  · exact ⟨origin, original, address⟩

theorem named_root_from_invariant
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (found : env.lookup key = some (observation, .ref root))
    (abstract : aenv.lookup key = some (.list roots element certificate)) :
    named gamma roots root := by
  have cells := inv.named key observation (.ref root) (.list roots element certificate)
    found abstract [] root rfl (.here _)
  have names : named gamma (namesAt (.list roots element certificate) []) root := by
    simpa only [namesAt] using cells
  rw [list_root_names] at names
  exact named_union_nil names

end Ownership.FlatFragment.NamingFacts

/-! membership facts for the checker's actual live-set union.
The local instances prove laws for the existing Boolean comparisons.
They change no checker operation or exported global instance.
-/

namespace Ownership.FlatFragment.LiveSets

open Ownership.FlatFragment.Description Ownership.FlatFragment.NamingFacts

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)

theorem mem_union_iff [BEq α] [LawfulBEq α] (left right : List α) (value : α) :
    value ∈ union left right ↔ value ∈ left ∨ value ∈ right :=
  ⟨mem_union_cases left right value, mem_union left right value⟩

theorem union_left (left right : Live) : ∀ use ∈ left, use ∈ union left right := by
  intro use member
  exact mem_union left right use (Or.inl member)

theorem union_right (left right : Live) : ∀ use ∈ right, use ∈ union left right := by
  intro use member
  exact mem_union left right use (Or.inr member)

theorem rhs_live_subset (rhs rest after : Live) :
    ∀ use ∈ union rhs (union after rest), use ∈ union (union rhs rest) after := by
  intro use member
  rcases mem_union_cases rhs (union after rest) use member with first | later
  · exact union_left _ _ use (union_left _ _ use first)
  · rcases mem_union_cases after rest use later with outer | continuation
    · exact union_right _ _ use outer
    · exact union_left _ _ use (union_right _ _ use continuation)

theorem removeVars_keeps_other {use : Var × Path} {live : Live} (binder : Var) (different : use.1 ≠ binder)
    (member : use ∈ live) : use ∈ removeVars [binder] live := by
  simp [removeVars, member, different, Ne.symm different]

theorem continuation_old_live {use : Var × Path} (binder : Var) (rest after : Live)
    (different : use.1 ≠ binder) (member : use ∈ union rest after) :
    use ∈ union after (removeVars [binder] rest) := by
  rcases mem_union_cases rest after use member with next | outer
  · exact union_right _ _ use (removeVars_keeps_other binder different next)
  · exact union_left _ _ use outer

end Ownership.FlatFragment.LiveSets

/-! membership facts for the checker's actual live-cell fold.
The roots of a live list binding belong to the live cells of any live set
that uses the binding at any path. The proofs follow the real `liveCells`
fold and the real `union`. No checker operation changes.
-/

namespace Ownership.FlatFragment.LiveCells

open Ownership.FlatFragment.Description Ownership.FlatFragment.NamingFacts

local instance stepReflBEq : ReflBEq Step := ⟨by deriving_ReflEq_tactic⟩
local instance stepLawfulBEq : LawfulBEq Step := LawfulBEq.mk (by deriving_LawfulEq_tactic)
local instance originReflBEq : ReflBEq Origin := ⟨by deriving_ReflEq_tactic⟩
local instance originLawfulBEq : LawfulBEq Origin := LawfulBEq.mk (by deriving_LawfulEq_tactic)

theorem foldl_mono {β : Type} (f : List Origin → β → List Origin)
    (mono : ∀ cs b, ∀ o ∈ cs, o ∈ f cs b) (items : List β) (init : List Origin) :
    ∀ o ∈ init, o ∈ items.foldl f init := by
  induction items generalizing init with
  | nil => intro o member; exact member
  | cons b items ih => intro o member; exact ih (f init b) o (mono init b o member)

theorem foldl_member {β : Type} (f : List Origin → β → List Origin)
    (mono : ∀ cs b, ∀ o ∈ cs, o ∈ f cs b) (items : List β) (init : List Origin)
    (b : β) (present : b ∈ items) (o : Origin) (adds : ∀ cs, o ∈ f cs b) :
    o ∈ items.foldl f init := by
  induction items generalizing init with
  | nil => simp at present
  | cons first items ih =>
    rcases List.mem_cons.mp present with rfl | later
    · exact foldl_mono f mono items _ o (adds init)
    · exact ih _ later

/-- The inner fold of `liveCells` over the paths of one abstract value. -/
def pathStep (p : Path) (cs : List Origin) (entry : Path × List Origin) : List Origin :=
  if isPrefix p entry.1 || isPrefix entry.1 p then union cs entry.2 else cs

theorem pathStep_mono (p : Path) : ∀ cs entry, ∀ o ∈ cs, o ∈ pathStep p cs entry := by
  intro cs entry o member
  unfold pathStep
  split
  · exact mem_union cs entry.2 o (Or.inl member)
  · exact member

/-- The outer fold of `liveCells` over the live uses. -/
def useStep (env : Env Abstract) (cs : List Origin) (use : Var × Path) : List Origin :=
  match env.lookup use.1 with
  | none => union cs [.unknown]
  | some a => a.paths.foldl (pathStep use.2) cs

theorem useStep_mono (env : Env Abstract) : ∀ cs use, ∀ o ∈ cs, o ∈ useStep env cs use := by
  intro cs use o member
  unfold useStep
  split
  · exact mem_union cs [.unknown] o (Or.inl member)
  · exact foldl_mono _ (pathStep_mono use.2) _ cs o member

theorem liveCells_eq_fold (env : Env Abstract) (l : Live) :
    liveCells env l = l.foldl (useStep env) [] := by
  unfold liveCells useStep pathStep
  rfl

theorem isPrefix_nil (p : Path) : isPrefix [] p = true := by
  simp [isPrefix]

/-- The roots of a live list binding are live cells, at every use path. -/
theorem roots_in_liveCells (env : Env Abstract) (l : Live) (x : Var) (p : Path)
    (use : (x, p) ∈ l) (found : env.lookup x = some (.list roots element certificate)) :
    ∀ o ∈ roots, o ∈ liveCells env l := by
  intro o member
  rw [liveCells_eq_fold]
  apply foldl_member (useStep env) (useStep_mono env) l [] (x, p) use o
  intro cs
  unfold useStep
  simp only [found, Abstract.paths, List.foldl_cons]
  apply foldl_mono _ (pathStep_mono p)
  unfold pathStep
  simp only [isPrefix_nil, Bool.or_true, if_true]
  exact mem_union cs roots o (Or.inr member)

end Ownership.FlatFragment.LiveCells

/-! liveness facts for the exact flat fragment.
The caller derives empty paths from the permitted syntax. No interpreter
result or final agreement premise enters these bookkeeping lemmas. -/

namespace Ownership.FlatFragment.Liveness

open Ownership.FlatFragment.Support

/-- The uses of an integer primitive are its operands' uses. -/
theorem uses_scalar {op : Prim} {a b : Atom} (sop : ScalarOp op) :
    uses (.prim op [a, b]) = atomsUses [a, b] := by
  cases sop <;> rfl

theorem uses_record (args : List Atom) : uses (.prim .record args) = atomsUses args := rfl

theorem uses_ok (error : Ty) (x : Atom) : uses (.prim (.ok error) [x]) = atomsUses [x] := rfl

theorem uses_err (success : Ty) (x : Atom) : uses (.prim (.err success) [x]) = atomsUses [x] := rfl

theorem uses_resultCase (input : Atom) (err ok : Var) (onError onSuccess : Expr) :
    uses (.resultCase input err ok onError onSuccess) =
      union (atomUses input)
        (union (removeVars [err] (uses onError)) (removeVars [ok] (uses onSuccess))) := rfl

theorem uses_endChain : uses (.prim (.endChain .int) []) = atomsUses [] := rfl

theorem uses_link (head tail : Atom) : uses (.prim .link [head, tail]) = atomsUses [head, tail] := rfl

theorem uses_chainCase (input : Atom) (head tail : Var) (onEnd onLink : Expr) :
    uses (.chainCase input head tail onEnd onLink) =
      union (atomUses input) (union (uses onEnd) (removeVars [head, tail] (uses onLink))) := rfl

theorem uses_at (receiver index fallback : Atom) :
    uses (.prim .at [receiver, index, fallback]) = atomsUses [receiver, index, fallback] := rfl

theorem uses_set (receiver index item : Atom) :
    uses (.prim .set [receiver, index, item]) = atomsUses [receiver, index, item] := rfl

theorem uses_copy (receiver : Atom) : uses (.prim .copy [receiver]) = atomsUses [receiver] := rfl

theorem uses_prepend (item receiver : Atom) :
    uses (.prim .prepend [item, receiver]) = atomsUses [item, receiver] := rfl

theorem uses_dictInsert (receiver key item : Atom) :
    uses (.prim .dictInsert [receiver, key, item]) = atomsUses [receiver, key, item] := rfl

theorem uses_dictRemove (receiver key : Atom) :
    uses (.prim .dictRemove [receiver, key]) = atomsUses [receiver, key] := rfl

theorem uses_dictGet (receiver key : Atom) :
    uses (.prim .dictGet [receiver, key]) = atomsUses [receiver, key] := rfl

theorem uses_view (front : Bool) (receiver : Atom) :
    uses (.prim (.view front) [receiver]) = atomsUses [receiver] := rfl

theorem uses_dictSize (receiver : Atom) :
    uses (.prim .dictSize [receiver]) = atomsUses [receiver] := rfl

theorem flatExpr_default_uses (flat : FlatANF0 expression) :
    usesWith ({} : Config) expression = uses expression := by
  induction flat with
  | scalar sop => cases sop <;> simp [usesWith, uses, usesArms, Config.has]
  | atom => simp_all [usesWith, uses, usesArms, Config.has]
  | letE _ _ _ _ => simp_all [usesWith, uses, usesArms, Config.has]
  | literal => simp_all [usesWith, uses, usesArms, Config.has]
  | push => simp_all [usesWith, uses, usesArms, Config.has]
  | length => simp_all [usesWith, uses, usesArms, Config.has]
  | shared => simp_all [usesWith, uses, usesArms, Config.has]
  | record => simp_all [usesWith, uses, usesArms, Config.has]
  | branch _ _ _ _ => simp_all [usesWith, uses, usesArms, Config.has]
  | ok _ => simp_all [usesWith, uses, usesArms, Config.has]
  | err _ => simp_all [usesWith, uses, usesArms, Config.has]
  | resultCase _ _ _ _ => simp_all [usesWith, uses, usesArms, Config.has]
  | endChain => simp_all [usesWith, uses, usesArms, Config.has]
  | link => simp_all [usesWith, uses, usesArms, Config.has]
  | chainCase _ _ _ _ => simp_all [usesWith, uses, usesArms, Config.has]
  | atRead => simp_all [usesWith, uses, usesArms, Config.has]
  | set => simp_all [usesWith, uses, usesArms, Config.has]
  | copy => simp_all [usesWith, uses, usesArms, Config.has]
  | prepend => simp_all [usesWith, uses, usesArms, Config.has]
  | dictEmpty _ _ => simp_all [usesWith, uses, usesArms, Config.has]
  | dictInsert => simp_all [usesWith, uses, usesArms, Config.has]
  | dictRemove => simp_all [usesWith, uses, usesArms, Config.has]
  | dictGet => simp_all [usesWith, uses, usesArms, Config.has]
  | dictSize => simp_all [usesWith, uses, usesArms, Config.has]
  | view _ => simp_all [usesWith, uses, usesArms, Config.has]
  | object => simp_all [usesWith, uses, usesArms, Config.has]
  | get _ => simp_all [usesWith, uses, usesArms, Config.has]
  | recordCopy => simp_all [usesWith, uses, usesArms, Config.has]
  | assign => simp_all [usesWith, uses, usesArms, Config.has]

end Ownership.FlatFragment.Liveness

/-! paths through records: the variable and field path an atom reads, the type
at a field path, and the runtime and checker evaluation of an atom from its
root binding. No theorem below uses a pinned soundness obligation. -/

namespace Ownership.FlatFragment.Fields

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.Support Ownership.FlatFragment.State

/-! ### Paths -/

/-- The variable and the field path an atom reads; an integer reads none. -/
def atomRoot : Atom → Option (Var × Path)
  | .int _ => none
  | .var v => some (v, [])
  | .field a i => (atomRoot a).map fun (v, p) => (v, p ++ [.field i])

theorem atomRoot_field {a : Atom} {i : Nat} {k : Var} {p : Path}
    (root : atomRoot (.field a i) = some (k, p)) :
    ∃ p0, atomRoot a = some (k, p0) ∧ p = p0 ++ [.field i] := by
  simp only [atomRoot, Option.map_eq_some_iff] at root
  obtain ⟨⟨v', p'⟩, inner, equal⟩ := root
  simp only [Prod.mk.injEq] at equal
  obtain ⟨rfl, rfl⟩ := equal
  exact ⟨p', inner, rfl⟩

theorem atomUses_of_root {a : Atom} {v : Var} {p : Path} (root : atomRoot a = some (v, p)) :
    atomUses a = [(v, p)] := by
  induction a generalizing v p with
  | int n => simp [atomRoot] at root
  | var x =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    rfl
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    simp [atomUses, ih inner]

theorem atomType_field {tenv : Env Ty} {a : Atom} {i : Nat} {ty : Ty}
    (typed : atomType tenv (.field a i) = .ok ty) :
    ∃ fs, atomType tenv a = .ok (.record fs) ∧ fs[i]? = some ty := by
  unfold atomType at typed
  cases h : atomType tenv a with
  | error m => rw [h] at typed; simp [Bind.bind, Except.bind] at typed
  | ok t =>
    cases t <;> simp [h] at typed
    rename_i fs
    refine ⟨fs, rfl, ?_⟩
    cases h' : fs[i]? with
    | none => simp [h', Option.toExcept] at typed
    | some u =>
      simp [h', Option.toExcept] at typed
      exact congrArg some typed

/-- A typed atom without a root is an integer literal. -/
theorem atom_int_of_root_none {tenv : Env Ty} {a : Atom} {ty : Ty}
    (typed : atomType tenv a = .ok ty) (root : atomRoot a = none) :
    ∃ n, a = .int n ∧ ty = .int := by
  induction a generalizing ty with
  | int n =>
    change Except.ok Ty.int = Except.ok ty at typed
    cases Except.ok.inj typed
    exact ⟨n, rfl, rfl⟩
  | var v => simp [atomRoot] at root
  | field a i ih =>
    simp only [atomRoot, Option.map_eq_none_iff] at root
    obtain ⟨fs, inner, _⟩ := atomType_field typed
    obtain ⟨n, _, bad⟩ := ih inner root
    cases bad

theorem fieldTyAt_snoc {t u : Ty} {p : Path} {fs : List Ty} {i : Nat}
    (at_p : fieldTyAt t p = some (.record fs)) (field : fs[i]? = some u) :
    fieldTyAt t (p ++ [.field i]) = some u := by
  induction p generalizing t with
  | nil =>
    simp [fieldTyAt] at at_p
    subst at_p
    simp [fieldTyAt, field]
  | cons step rest ih =>
    cases step <;> cases t <;> simp [fieldTyAt] at at_p ⊢
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      exact ih at_p

theorem tyAt_snoc {t u : Ty} {p : Path} {fs : List Ty} {i : Nat}
    (at_p : tyAt t p = some (.record fs)) (field : fs[i]? = some u) :
    tyAt t (p ++ [.field i]) = some u := by
  induction p generalizing t with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    simp [tyAt, field]
  | cons step rest ih =>
    cases step <;> cases t <;> simp [tyAt] at at_p ⊢
    · rename_i i' ts
      cases h : ts[i']? with
      | none => simp [h] at at_p
      | some t' =>
        simp [h] at at_p
        exact ih at_p
    · exact fieldTyAt_snoc at_p field

theorem fieldTyAt_snoc_inv {t u : Ty} {p : Path} {i : Nat}
    (at_snoc : fieldTyAt t (p ++ [.field i]) = some u) :
    ∃ fs, fieldTyAt t p = some (.record fs) ∧ fs[i]? = some u := by
  induction p generalizing t with
  | nil =>
    cases t <;> simp [fieldTyAt] at at_snoc
    rename_i ts
    cases h : ts[i]? with
    | none => simp [h] at at_snoc
    | some t' =>
      simp [h] at at_snoc
      subst at_snoc
      exact ⟨ts, rfl, h⟩
  | cons step rest ih =>
    cases step <;> cases t <;> simp [fieldTyAt] at at_snoc ⊢
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_snoc
    | some t' =>
      simp [h] at at_snoc
      exact ih at_snoc

theorem tyAt_snoc_inv {t u : Ty} {p : Path} {i : Nat}
    (at_snoc : tyAt t (p ++ [.field i]) = some u) :
    ∃ fs, tyAt t p = some (.record fs) ∧ fs[i]? = some u := by
  induction p generalizing t with
  | nil =>
    cases t <;> simp [tyAt] at at_snoc
    rename_i ts
    cases h : ts[i]? with
    | none => simp [h] at at_snoc
    | some t' =>
      simp [h] at at_snoc
      subst at_snoc
      exact ⟨ts, rfl, h⟩
  | cons step rest ih =>
    cases step <;> cases t <;> simp [tyAt] at at_snoc ⊢
    · rename_i i' ts
      cases h : ts[i']? with
      | none => simp [h] at at_snoc
      | some t' =>
        simp [h] at at_snoc
        exact ih at_snoc
    · exact fieldTyAt_snoc_inv at_snoc

/-- Typing an atom with a root: the variable's type has the atom's type at the path. -/
theorem atom_type_of_root {tenv : Env Ty} {a : Atom} {ty : Ty} {k : Var} {p : Path}
    (typed : atomType tenv a = .ok ty) (root : atomRoot a = some (k, p)) :
    ∃ tk, tenv.lookup k = some tk ∧ tyAt tk p = some ty := by
  induction a generalizing ty k p with
  | int n => simp [atomRoot] at root
  | var v =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    have typeRun : lookup tenv v = .ok ty := by simpa only [atomType] using typed
    exact ⟨ty, lookup_option_of_success typeRun, rfl⟩
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    obtain ⟨fs, innerTyped, field⟩ := atomType_field typed
    obtain ⟨tk, declared, at_p0⟩ := ih innerTyped inner
    exact ⟨tk, declared, tyAt_snoc at_p0 field⟩

/-- Typing an atom with a root: the path is a field path. -/
theorem atom_fieldType_of_root {tenv : Env Ty} {a : Atom} {ty : Ty} {k : Var} {p : Path}
    (typed : atomType tenv a = .ok ty) (root : atomRoot a = some (k, p)) :
    ∃ tk, tenv.lookup k = some tk ∧ fieldTyAt tk p = some ty := by
  induction a generalizing ty k p with
  | int n => simp [atomRoot] at root
  | var v =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    have typeRun : lookup tenv v = .ok ty := by simpa only [atomType] using typed
    exact ⟨ty, lookup_option_of_success typeRun, rfl⟩
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    obtain ⟨fs, innerTyped, field⟩ := atomType_field typed
    obtain ⟨tk, declared, at_p0⟩ := ih innerTyped inner
    exact ⟨tk, declared, fieldTyAt_snoc at_p0 field⟩

/-! ### Projections -/

theorem projectObs_snoc_inv {o o' : Observation} {p : Path} {i : Nat}
    (projected : projectObs o (p ++ [.field i]) = some o') :
    ∃ os, projectObs o p = some (.record os) ∧ os[i]? = some o' := by
  induction p generalizing o with
  | nil =>
    cases o <;> simp [projectObs] at projected
    rename_i os
    cases h : os[i]? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      subst projected
      exact ⟨os, rfl, h⟩
  | cons step rest ih =>
    cases step with
    | element =>
      cases o with
      | list items =>
        obtain ⟨xs, rfl, inner⟩ := projectObs_element_inv projected
        simp only [projectObs]
        exact ih inner
      | _ => simp [projectObs] at projected
    | field i' =>
      cases o <;> simp [projectObs] at projected ⊢
      rename_i os
      cases h : os[i']? with
      | none => simp [h] at projected
      | some x =>
        simp [h] at projected
        exact ih projected
    | _ => cases o <;> simp [projectObs] at projected

theorem projectObs_snoc {o o' : Observation} {os : List Observation} {p : Path} {i : Nat}
    (projected : projectObs o p = some (.record os)) (field : os[i]? = some o') :
    projectObs o (p ++ [.field i]) = some o' := by
  induction p generalizing o with
  | nil =>
    simp [projectObs] at projected
    subst projected
    simp [projectObs, field]
  | cons step rest ih =>
    cases step with
    | element =>
      cases o with
      | list items =>
        obtain ⟨xs, rfl, inner⟩ := projectObs_element_inv projected
        simp only [List.cons_append, projectObs]
        exact ih inner
      | _ => simp [projectObs] at projected
    | field i' =>
      cases o <;> simp [projectObs] at projected ⊢
      rename_i os'
      cases h : os'[i']? with
      | none => simp [h] at projected
      | some x =>
        simp [h] at projected
        exact ih projected
    | _ => cases o <;> simp [projectObs] at projected

theorem projectHeap_snoc_inv {heap : Heap} {w w' : Value} {p : Path} {i : Nat}
    (projected : projectHeap heap w (p ++ [.field i]) = some w') :
    ∃ ws, projectHeap heap w p = some (.record ws) ∧ ws[i]? = some w' := by
  induction p generalizing w with
  | nil =>
    cases w <;> simp [projectHeap] at projected
    rename_i ws
    cases h : ws[i]? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      subst projected
      exact ⟨ws, rfl, h⟩
  | cons step rest ih =>
    cases step with
    | element =>
      cases w with
      | ref c =>
        obtain ⟨xs, found, inner⟩ := projectHeap_element_inv projected
        rw [projectHeap_element found]
        exact ih inner
      | _ => simp [projectHeap] at projected
    | field i' =>
      cases w <;> simp [projectHeap] at projected ⊢
      rename_i ws
      cases h : ws[i']? with
      | none => simp [h] at projected
      | some x =>
        simp [h] at projected
        exact ih projected
    | _ => cases w <;> simp [projectHeap] at projected

theorem projectHeap_snoc {heap : Heap} {w w' : Value} {ws : List Value} {p : Path} {i : Nat}
    (projected : projectHeap heap w p = some (.record ws)) (field : ws[i]? = some w') :
    projectHeap heap w (p ++ [.field i]) = some w' := by
  induction p generalizing w with
  | nil =>
    simp [projectHeap] at projected
    subst projected
    simp [projectHeap, field]
  | cons step rest ih =>
    cases step with
    | element =>
      cases w with
      | ref c =>
        obtain ⟨xs, found, inner⟩ := projectHeap_element_inv projected
        rw [List.cons_append, projectHeap_element found]
        exact ih inner
      | _ => simp [projectHeap] at projected
    | field i' =>
      cases w <;> simp [projectHeap] at projected ⊢
      rename_i ws'
      cases h : ws'[i']? with
      | none => simp [h] at projected
      | some x =>
        simp [h] at projected
        exact ih projected
    | _ => cases w <;> simp [projectHeap] at projected

/-- A projection along a concatenated path is the projection of the second
part from the first part's value. -/
theorem projectHeap_append {heap : Heap} : ∀ {w : Value} {p r : Path},
    projectHeap heap w (p ++ r) = (projectHeap heap w p).bind (projectHeap heap · r) := by
  intro w p r
  induction p generalizing w with
  | nil => simp [projectHeap]
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectHeap]
    · rename_i i ws
      cases ws[i]? with
      | none => rfl
      | some x => exact ih
    · rename_i c
      split
      · exact ih
      · rfl

/-- On a path of record fields, a projection reads no heap. -/
theorem projectHeap_fields {heap heap' : Heap} : ∀ {w : Value} {q : Path},
    (∀ s ∈ q, ∃ i, s = Step.field i) → projectHeap heap w q = projectHeap heap' w q := by
  intro w q fields
  induction q generalizing w with
  | nil => simp [projectHeap]
  | cons step rest ih =>
    obtain ⟨i, rfl⟩ := fields step (by simp)
    cases w <;> simp [projectHeap]
    rename_i ws
    cases ws[i]? with
    | none => rfl
    | some x => exact ih (fun s member => fields s (List.mem_cons_of_mem _ member))

/-- A field read through a record object's slot: the object, its one slot,
and the field (#316). -/
theorem projectHeap_slot {heap : Heap} {w v : Value} {q : Path} {g : Nat}
    (projected : projectHeap heap w (q ++ [.element, .field g]) = some v) :
    ∃ c xs, projectHeap heap w q = some (.ref c) ∧ heap[c]? = some [.record xs] ∧ xs[g]? = some v := by
  rw [projectHeap_append] at projected
  cases found : projectHeap heap w q with
  | none => rw [found] at projected; cases projected
  | some u =>
    rw [found] at projected
    simp only [Option.bind_some] at projected
    cases u with
    | ref c =>
      simp only [projectHeap] at projected
      cases lookup : heap[c]? with
      | none => rw [lookup] at projected; cases projected
      | some ys =>
        rw [lookup] at projected
        match ys, lookup, projected with
        | [y], lookup, projected =>
          cases y with
          | record xs =>
            simp only [projectHeap] at projected
            cases at_g : xs[g]? with
            | none => rw [at_g] at projected; cases projected
            | some x =>
              rw [at_g] at projected
              simp only [projectHeap, Option.some.injEq] at projected
              subst projected
              exact ⟨c, xs, rfl, lookup, at_g⟩
          | _ => simp [projectHeap] at projected
        | [], _, projected => simp at projected
        | _ :: _ :: _, _, projected => simp at projected
    | _ => simp [projectHeap] at projected

/-- No marked field selects nothing. -/
theorem selectFields_nil_of_none {α : Type} : ∀ {keep : List Bool} {xs : List α},
    (∀ g : Nat, keep[g]? ≠ some true) → selectFields keep xs = []
  | [], _, _ => by simp [selectFields]
  | _ :: _, [], _ => by simp [selectFields]
  | b :: bs, x :: xs, nothing => by
    cases b with
    | true => exact absurd rfl (nothing 0)
    | false =>
      simp only [selectFields, Bool.false_eq_true, if_false]
      exact selectFields_nil_of_none (fun g kept => nothing (g + 1) (by simpa using kept))

/-- Two field lists that agree at every marked field select the same fields. -/
theorem selectFields_congr {α : Type} : ∀ {keep : List Bool} {xs ys : List α},
    (∀ g : Nat, keep[g]? = some true → ∃ v, xs[g]? = some v ∧ ys[g]? = some v) →
      selectFields keep xs = selectFields keep ys
  | [], _, _, _ => by simp [selectFields]
  | b :: bs, [], [], _ => rfl
  | b :: bs, x :: xs, [], agree => by
    cases b with
    | true => obtain ⟨v, _, absent⟩ := agree 0 rfl; simp at absent
    | false =>
      simp only [selectFields, Bool.false_eq_true, if_false]
      exact selectFields_nil_of_none (fun g kept => by
        obtain ⟨v, _, absent⟩ := agree (g + 1) (by simpa using kept)
        simp at absent)
  | b :: bs, [], y :: ys, agree => by
    cases b with
    | true => obtain ⟨v, absent, _⟩ := agree 0 rfl; simp at absent
    | false =>
      simp only [selectFields, Bool.false_eq_true, if_false]
      exact (selectFields_nil_of_none (fun g kept => by
        obtain ⟨v, absent, _⟩ := agree (g + 1) (by simpa using kept)
        simp at absent)).symm
  | b :: bs, x :: xs, y :: ys, agree => by
    have rest := selectFields_congr (keep := bs) (xs := xs) (ys := ys)
      (fun g kept => by simpa using agree (g + 1) (by simpa using kept))
    cases b with
    | true =>
      obtain ⟨v, hx, hy⟩ := agree 0 rfl
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hx hy
      subst hx; subst hy
      simp only [selectFields, if_true, rest]
    | false => simp only [selectFields, Bool.false_eq_true, if_false, rest]

/-! ### Atom evaluation by root and path -/

theorem lookup_ok_of_option {α : Type} [Inhabited α] {env : Env α} {key : Var} {value : α}
    (found : env.lookup key = some value) : lookup env key = .ok value := by
  simp [lookup, found]

theorem value_atom_of_root {renv : Env Observation} {a : Atom} {k : Var} {p : Path}
    {o o' : Observation}
    (root : atomRoot a = some (k, p)) (found : renv.lookup k = some o)
    (projected : projectObs o p = some o') :
    ValueSemantics.atom renv a = .ok o' := by
  induction a generalizing k p o' with
  | int n => simp [atomRoot] at root
  | var v =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    simp [projectObs] at projected
    subst projected
    simp [ValueSemantics.atom, lookup, found]
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    obtain ⟨os, innerProjected, at_i⟩ := projectObs_snoc_inv projected
    have run := ih inner found innerProjected
    simp [ValueSemantics.atom, run, at_i, Option.toExcept]

theorem heap_atom_of_root {heap : Heap} {renv : Env Value} {a : Atom} {k : Var} {p : Path} {w w' : Value}
    (root : atomRoot a = some (k, p)) (found : renv.lookup k = some w)
    (projected : projectHeap heap w p = some w') :
    InPlaceSemantics.atom renv a = .ok w' := by
  induction a generalizing k p w' with
  | int n => simp [atomRoot] at root
  | var v =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    simp [projectHeap] at projected
    subst projected
    simp [InPlaceSemantics.atom, lookup, found]
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    obtain ⟨ws, innerProjected, at_i⟩ := projectHeap_snoc_inv projected
    have run := ih inner found innerProjected
    simp [InPlaceSemantics.atom, run, at_i, Option.toExcept]

theorem flatType_tyAt {tk ty : Ty} {p : Path} (flat : FlatType tk) (at_p : tyAt tk p = some ty) :
    FlatType ty := by
  induction p generalizing tk with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    exact flat
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    · rename_i i' ts
      cases h : ts[i']? with
      | none => simp [h] at at_p
      | some t' =>
        simp [h] at at_p
        cases flat with
        | record _ fields => exact ih (fields t' (List.mem_of_getElem? h)) at_p
    · cases flat with
      | object _ fields => exact ih (.record _ fields) (tyAt_of_fieldTyAt at_p)

/-- The bottom of dead code has no path below it. -/
theorem atPath_bottom (p : Path) : Abstract.bottom.atPath p = .bottom := by
  cases p with
  | nil => rfl
  | cons step rest => cases step <;> rfl

theorem flatAbstract_record {ts : List Ty} {a : Abstract} (shape : FlatAbstract (.record ts) a) :
    a = .bottom ∨ ∃ as, a = .record as ∧ ts.length = as.length ∧
      ∀ (i : Nat) (t : Ty) (a' : Abstract), ts[i]? = some t → as[i]? = some a' → FlatAbstract t a' := by
  cases shape with
  | bottom _ => exact Or.inl rfl
  | record _ as len fields => exact Or.inr ⟨as, rfl, len, fields⟩

theorem flatAbstract_object {ts : List Ty} {a : Abstract} (shape : FlatAbstract (.object ts) a) :
    a = .bottom ∨ ∃ roots element certificate, a = .list roots element certificate ∧
      Origin.unknown ∉ roots ∧ FlatAbstract (.record ts) element := by
  cases shape with
  | bottom _ => exact Or.inl rfl
  | object _ roots element certificate noUnk elementShape =>
    exact Or.inr ⟨roots, element, certificate, rfl, noUnk, elementShape⟩

theorem index_of_same_length {α β : Type} {xs : List α} {ys : List β} {i : Nat} {x : α}
    (len : xs.length = ys.length) (at_i : xs[i]? = some x) :
    ∃ y, ys[i]? = some y := by
  have lt : i < ys.length := len ▸ (List.getElem?_eq_some_iff.mp at_i).1
  exact ⟨ys[i], List.getElem?_eq_getElem lt⟩

theorem flatAbstract_record_field {ts : List Ty} {as : List Abstract} {i : Nat} {t : Ty}
    (len : ts.length = as.length)
    (fields : ∀ (i : Nat) (t : Ty) (a : Abstract), ts[i]? = some t → as[i]? = some a → FlatAbstract t a)
    (at_i : ts[i]? = some t) :
    ∃ a', as[i]? = some a' ∧ FlatAbstract t a' := by
  obtain ⟨a', as_i⟩ := index_of_same_length len at_i
  exact ⟨a', as_i, fields i t a' at_i as_i⟩

theorem atPath_snoc_of_tyAt {tk ty : Ty} {a : Abstract} {p : Path} {i : Nat}
    (shape : FlatAbstract tk a) (at_p : tyAt tk (p ++ [.field i]) = some ty) :
    a.atPath (p ++ [.field i]) = (a.atPath p).atPath [.field i] := by
  induction p generalizing tk a with
  | nil => simp [Abstract.atPath]
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    · rename_i i' ts
      cases h : ts[i']? with
      | none => simp [h] at at_p
      | some t' =>
        simp [h] at at_p
        rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
        · rw [atPath_bottom, atPath_bottom, atPath_bottom]
        · obtain ⟨a', at_i, shape'⟩ := flatAbstract_record_field len fields h
          simp only [List.cons_append, Abstract.atPath, at_i, Option.getD_some]
          exact ih shape' at_p
    · rcases flatAbstract_object shape with rfl | ⟨roots, element, certificate, rfl, _, shape'⟩
      · rw [atPath_bottom, atPath_bottom, atPath_bottom]
      · simp only [List.cons_append, Abstract.atPath]
        exact ih shape' (tyAt_of_fieldTyAt at_p)

theorem flatAbstract_atPath {tk ty : Ty} {a : Abstract} {p : Path}
    (shape : FlatAbstract tk a) (at_p : tyAt tk p = some ty) : FlatAbstract ty (a.atPath p) := by
  induction p generalizing tk a with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    simpa [Abstract.atPath] using shape
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    · rename_i i' ts
      cases h : ts[i']? with
      | none => simp [h] at at_p
      | some t' =>
        simp [h] at at_p
        rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
        · rw [atPath_bottom]; exact .bottom _
        · obtain ⟨a', at_i, shape'⟩ := flatAbstract_record_field len fields h
          simp only [Abstract.atPath, at_i, Option.getD_some]
          exact ih shape' at_p
    · rcases flatAbstract_object shape with rfl | ⟨roots, element, certificate, rfl, _, shape'⟩
      · rw [atPath_bottom]; exact .bottom _
      · simp only [Abstract.atPath]
        exact ih shape' (tyAt_of_fieldTyAt at_p)

end Ownership.FlatFragment.Fields

/-! The live clause through the type (#1796). At a live path whose type has
no dictionary, the typed abstract is the abstract. -/

namespace Ownership.FlatFragment.VariableFacts

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

end Ownership.FlatFragment.VariableFacts

namespace Ownership.FlatFragment.State

open InPlaceSemantics HeapProof Soundness Ownership.FlatFragment.Fields

theorem fieldTyAt_entryType {ty t : Ty} {p : Path} (typed : fieldTyAt ty p = some t) :
    fieldTyAt (entryType ty) p = some (entryType t) := by
  induction p generalizing ty with
  | nil =>
    simp [fieldTyAt] at typed
    subst typed
    rfl
  | cons step rest ih =>
    cases step <;> cases ty <;> simp [fieldTyAt] at typed
    rename_i i ts
    cases found : ts[i]? with
    | none => simp [found] at typed
    | some t' =>
      simp only [found] at typed
      show (match (entryTypes ts)[i]? with
        | some t => fieldTyAt t rest
        | none => none) = _
      rw [entryTypes_getElem?, found]
      exact ih typed

/-- The representation of a typed path's type is at the same path of the
    representation. -/
theorem tyAt_entryType {ty t : Ty} {p : Path} (typed : tyAt ty p = some t) :
    tyAt (entryType ty) p = some (entryType t) := by
  induction p generalizing ty with
  | nil =>
    simp [tyAt] at typed
    subst typed
    rfl
  | cons step rest ih =>
    cases step <;> cases ty <;> simp [tyAt] at typed
    · rename_i i ts
      cases found : ts[i]? with
      | none => simp [found] at typed
      | some t' =>
        simp only [found] at typed
        show (match (entryTypes ts)[i]? with
          | some t => tyAt t rest
          | none => none) = _
        rw [entryTypes_getElem?, found]
        exact ih typed
    · rename_i ts
      show fieldTyAt (entryType (.record ts)) rest = _
      exact fieldTyAt_entryType typed

/-- Reading through the type commutes with a typed field projection. -/
theorem entryAbstract_atPath {ds : List Decl} {ty t : Ty} {a : Abstract} {p : Path}
    (shape : FlatAbstract ty a) (typed : tyAt ty p = some t) :
    (entryAbstract ds ty a).atPath p = entryAbstract ds t (a.atPath p) := by
  induction p generalizing ty a with
  | nil =>
    simp [tyAt] at typed
    subst typed
    rfl
  | cons step rest ih =>
    cases step <;> cases ty <;> simp [tyAt] at typed
    · rename_i i ts
      cases found : ts[i]? with
      | none => simp [found] at typed
      | some t' =>
        simp only [found] at typed
        rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
        · rw [entryAbstract_bottom, atPath_bottom, entryAbstract_bottom]
        · obtain ⟨a', at_i, shape'⟩ := flatAbstract_record_field len fields found
          show (Abstract.record (entryFields ds ts as)).atPath (.field i :: rest) = _
          simp only [Abstract.atPath, at_i, Option.getD_some]
          rw [entryFields_getElem?, at_i, found]
          simp only [Option.map_some, Option.getD_some]
          exact ih shape' typed
    · rename_i ts
      rcases flatAbstract_object shape with rfl | ⟨roots, element, certificate, rfl, _, shape'⟩
      · rw [entryAbstract_bottom, atPath_bottom, entryAbstract_bottom]
      · show (Abstract.list roots (entryAbstract ds (.record ts) element) certificate).atPath (.element :: rest) = _
        simp only [Abstract.atPath]
        exact ih shape' (tyAt_of_fieldTyAt typed)

/-- At a typed path whose type has no dictionary, the typed abstract is the
    abstract. -/
theorem entryAbstract_atPath_flat {ds : List Decl} {ty t : Ty} {a : Abstract} {p : Path}
    (free : DictFree t) (shape : FlatAbstract ty a) (typed : tyAt ty p = some t) :
    entryAbstract ds (fieldType ty p) (a.atPath p) = a.atPath p := by
  rw [fieldType_of_tyAt typed]
  exact entryAbstract_of_dictFree free (flatAbstract_atPath shape typed)

/-- The live clause of a flat invariant at a typed path: the projection read
    through its type (#1796). -/
theorem FlatInvariant.described {declarations : List Decl} {vs : ValueSemantics.State}
    {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live}
    {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x p, (x, p) ∈ live → ∀ o w a ty t w', env.lookup x = some (o, w) → aenv.lookup x = some a →
      tenv.lookup x = some ty → tyAt ty p = some t → projectHeap hs.heap w p = some w' →
        Describes gamma hs.heap (entryAbstract declarations t (a.atPath p)) w' := by
  intro x p use o w a ty t w' binding found declared typed projected
  have described := inv.toInvariant.described x p use o w a ty w' binding found declared projected
  rwa [fieldType_of_tyAt typed] at described

/-- The live clause of a flat invariant at a typed path whose type has no
    dictionary: the projection is described by the abstract itself. -/
theorem FlatInvariant.described_dictFree {declarations : List Decl} {vs : ValueSemantics.State}
    {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live}
    {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming}
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x p, (x, p) ∈ live → ∀ o w a ty t w', env.lookup x = some (o, w) → aenv.lookup x = some a →
      tenv.lookup x = some ty → tyAt ty p = some t → DictFree t → projectHeap hs.heap w p = some w' →
        Describes gamma hs.heap (a.atPath p) w' := by
  intro x p use o w a ty t w' binding found declared typed free projected
  have described := inv.toInvariant.described x p use o w a ty w' binding found declared projected
  rwa [entryAbstract_atPath_flat free (inv.abstractShapes x ty a declared found) typed] at described

end Ownership.FlatFragment.State

namespace Ownership.FlatFragment.State

open InPlaceSemantics HeapProof Soundness

/-- A result whose type has no dictionary is its own representation (#1796):
    the success clause of an expression in its old form is the clause at the
    representation. -/
theorem success_of_dictFree {declarations : List Decl} {depth : Nat}
    {env : List (Var × Observation × Value)} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State}
    {e : Expr} {after : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes' : List Origin}
    {result : Abstract} {type : Ty}
    (free : DictFree type) (shape : FlatAbstract type result)
    (success : ∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env) e).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env) e).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env after aenv tenv escapes' gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧ Describes gamma' hs'.heap result actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        Ownership.FlatFragment.HeapPreservation.AllocatedFlatValue hs'.heap actual type ∧
        ResultTags type result actual ∧ ChainTags type result value ∧ TagsDeep hs'.heap type result actual ∧
        KindsAt hs' env tenv type actual) :
    ∀ value vs',
      (ValueSemantics.eval depth declarations none (valueEnv env) e).run vs = .ok (value, vs') →
      ∃ actual hs' gamma',
        (InPlaceSemantics.eval depth declarations none (heapEnv env) e).run hs = .ok (actual, hs') ∧
        FlatInvariant declarations vs' hs' env after aenv tenv escapes' gamma' ∧
        hs.heap.size ≤ hs'.heap.size ∧
        Corresponds hs'.heap value actual ∧
        Describes gamma' hs'.heap (entryAbstract declarations type result) actual ∧
        obsTyped declarations value type = true ∧ ValueTyped declarations hs'.heap actual type ∧
        Ownership.FlatFragment.HeapPreservation.AllocatedFlatValue hs'.heap actual (entryType type) ∧
        ResultTags (entryType type) (entryAbstract declarations type result) actual ∧
        ChainTags (entryType type) (entryAbstract declarations type result) value ∧
        TagsDeep hs'.heap (entryType type) (entryAbstract declarations type result) actual ∧
        KindsAt hs' env tenv type actual := by
  intro value vs' run
  rw [entryType_of_dictFree free, entryAbstract_of_dictFree free shape]
  exact success value vs' run

end Ownership.FlatFragment.State
