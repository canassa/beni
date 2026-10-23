import Ownership.LinkClauses

/-! The fragment modules form one import chain. Its first link imports
`LinkClauses`, which imports every other proof and executable module of the
package. The audit rejects an equation lemma that two modules realize, so a
module that unfolds a model definition must see every earlier realization. -/

/-! The first flat fragment: the predicate, demand and footprint support, the naming extension, flat descriptions, root names, live sets, live cells, and liveness bookkeeping. -/

/-! support for a separate flat ANF trace theorem.
No theorem below uses a pinned soundness obligation.
The demand lemmas take successful executions of the actual default checker
operation. They do not replace its test with an external permission oracle. -/

namespace Ownership.FlatFragment.State

/-- The binding types of the flat fragment: integers, integer lists, integer
chains, records of them and results over them, nested. A result's two types
are flat, so a case on it binds a flat payload; a chain case binds an integer
and a chain. -/
inductive FlatType : Ty → Prop where
  | int : FlatType .int
  | listInt : FlatType (.list .int)
  | chainInt : FlatType (.chain .int)
  | record (ts : List Ty) : (∀ t ∈ ts, FlatType t) → FlatType (.record ts)
  | result (error success : Ty) : FlatType error → FlatType success →
      FlatType (.result error success)

end Ownership.FlatFragment.State

namespace Ownership.FlatFragment.Fields

/-- The type at a field path. -/
def tyAt : Ty → Path → Option Ty
  | t, [] => some t
  | .record ts, .field i :: rest => match ts[i]? with
    | some t => tyAt t rest
    | none => none
  | _, _ => none

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

/-- The expression fragment. Every operand is any atom; accepted typing fixes
each to an integer, a variable or a variable under a field path, the literal
elements, the push item and the branch condition to `Int`, the length and
push receivers to `List Int`. The push receiver may be a field path: a write
through a field is in the fragment. A `branch` runs one of two fragment
expressions on an integer condition. `ok` and `err` build a result whose
other type is flat, and a `resultCase` binds the payload of a result to one
of two fragment arms. `endChain` and `link` build an integer chain, which
typing fixes to `Chain Int` (the link's head to `Int`), and a `chainCase`
runs one fragment arm on an empty chain or binds the head and the tail of a
nonempty one in the other. `at` reads an element of a list (an index and a
fallback, both `Int`), `set` writes one in place, `copy` allocates a copy,
and `prepend` allocates a copy with an item in front; typing fixes the
receivers to `List Int` and the items to `Int`. -/
inductive FlatANF0 : Expr → Prop where
  | atom : FlatANF0 (.atom a)
  | letE : FlatANF0 rhs → FlatANF0 rest → FlatANF0 (.letE v rhs rest)
  | literal : FlatANF0 (.prim (.literal .int) args)
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

theorem demand_success_not_escaped
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after)) :
    ∀ origin ∈ cs, ¬ Escaped before.facts.escapes origin :=
  demandProblem_none_not_escaped (demand_success_problem run)

/-- A successful checked demand cannot target any current permanent reader.
The invariant permits observers and aliases; it relates their origins to the
actual checker prefix's recorded escapes. -/
theorem demand_success_no_kept_reaches
    (inv : Invariant vs hs env live aenv before.facts.escapes gamma)
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
    (inv : Invariant vs hs env live aenv before.facts.escapes gamma)
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
    (inv : Invariant vs hs env live aenv before.facts.escapes gamma)
    (run : (demand ({} : Config) cs later others).run before = .ok (result, after))
    (receiver : named gamma cs root)
    (observers : RepresentsMany hs.heap depth hs.kept.toList observations footprint) :
    RepresentsMany (hs.heap.set! root stored) depth hs.kept.toList observations footprint :=
  representsMany_after_write observers (demand_success_observer_footprint inv run receiver observers)

theorem demand_success_observer_snapshots_after_write
    (inv : Invariant vs hs env live aenv before.facts.escapes gamma)
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
tags, `ResultTags`, say so). List descriptions retain bottom or scalar
elements. Dead aliases keep their old element description after a write.
The relation does not require uniqueness of a root or prohibit sharing
between runtime bindings. A record is described field by field. A result is
a record of a scalar tag and two payload slots, each the shape of its type
or bottom. -/
inductive FlatAbstract : Ty → Abstract → Prop where
  | bottom (ty : Ty) : FlatAbstract ty .bottom
  | int : FlatAbstract .int .scalar
  | listBottom (roots : List Origin) (certificate : Certificate) :
      FlatAbstract (.list .int) (.list roots .bottom certificate)
  | listScalar (roots : List Origin) (certificate : Certificate) :
      FlatAbstract (.list .int) (.list roots .scalar certificate)
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
  | listInt (roots : List Origin) (element : Abstract) (certificate : Certificate) (w : Value) :
      ResultTags (.list .int) (.list roots element certificate) w
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

/-- The chain tags of a binding's abstract and its observation. The checker
builds `endChain` with a bottom element and `link` with a scalar one, and a
join keeps a bottom element only when both sides have one; so a chain whose
element abstract is bottom is empty on the value side, through records and
the live slot of a result. A chain case binds its head to the element
abstract, so the relation says that an arm the runtime takes binds a scalar.
The relation reads no heap, so a write keeps it. -/
inductive ChainTags : Ty → Abstract → Observation → Prop where
  | int (a : Abstract) (o : Observation) : ChainTags .int a o
  | listInt (a : Abstract) (o : Observation) : ChainTags (.list .int) a o
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

/-- An integer primitive types only at two `Int` operands, and its result is `Int`. -/
theorem primType_scalar_success {op : Prim} {tyA tyB type : Ty} (sop : Ownership.FlatFragment.Support.ScalarOp op)
    (flatA : FlatType tyA) (flatB : FlatType tyB) (run : primType op [tyA, tyB] = .ok type) :
    tyA = .int ∧ tyB = .int ∧ type = .int := by
  cases sop <;> cases flatA <;> cases flatB <;> simp [primType] at run <;>
    first
    | (change Except.ok Ty.int = Except.ok type at run; cases Except.ok.inj run; exact ⟨rfl, rfl, rfl⟩)
    | (cases run; exact ⟨rfl, rfl, rfl⟩)

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

/-- The type environment supplies a type for every runtime lookup, including
dead bindings. The value observation retains its type, but its contents need
not match the current heap contents. `ValueTyped` supplies a complete finite
expansion of the current runtime value and therefore excludes dangling roots.

The abstract and type environments have the exact runtime key sequence.
Their descriptions have the flat shapes that real primitive inference needs
(`FlatAbstract`, which admits the bottom of dead code). The relation says
nothing about the arrays no binding holds: what a binding's arrays hold comes
from its type, through `bindingsTyped` (an integer list holds integers). The permanent
observer witness covers the complete current observer list at the runtime's
actual observation depth. Every binding's result tags agree with its
abstract (`ResultTags`), which also excludes a bottom where a value is, its
chain tags agree with its observation (`ChainTags`: a chain described with a
bottom element is empty), and every live use is a typed path of its binding,
so a projection of a live use never enters a result.
-/
structure FlatInvariant (declarations : List Decl)
    (vs : ValueSemantics.State) (hs : InPlaceSemantics.State)
    (env : List (Var × Observation × Value)) (live : Live)
    (aenv : Env Abstract) (tenv : Env Ty)
    (escapes : List Origin) (gamma : Naming) : Prop where
  toInvariant : Invariant vs hs env live aenv escapes gamma
  links : hs.links = []
  abstractKeys : env.map Prod.fst = aenv.map Prod.fst
  typeKeys : env.map Prod.fst = tenv.map Prod.fst
  types : ∀ x ty, tenv.lookup x = some ty → FlatType ty
  abstractShapes : ∀ x ty abstract,
    tenv.lookup x = some ty → aenv.lookup x = some abstract →
      FlatAbstract ty abstract
  bindingsTyped : ∀ x observation actual,
    env.lookup x = some (observation, actual) →
      ∃ ty, tenv.lookup x = some ty ∧
        obsTyped declarations observation ty = true ∧
        ValueTyped declarations hs.heap actual ty
  tags : ∀ x ty abstract observation actual,
    tenv.lookup x = some ty → aenv.lookup x = some abstract →
      env.lookup x = some (observation, actual) → ResultTags ty abstract actual
  chains : ∀ x ty abstract observation actual,
    tenv.lookup x = some ty → aenv.lookup x = some abstract →
      env.lookup x = some (observation, actual) → ChainTags ty abstract observation
  liveTyped : ∀ x p ty, (x, p) ∈ live → tenv.lookup x = some ty →
    ∃ t, Ownership.FlatFragment.Fields.tyAt ty p = some t
  namingBound : NamingBound gamma hs.heap.size
  observers : ∃ footprint,
    RepresentsMany hs.heap observationDepth hs.kept.toList vs.kept.toList footprint

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
      ∃ o' w', projectObs o p = some o' ∧ projectVal w p = some w' ∧ Corresponds hs.heap o' w' :=
  inv.toInvariant.bindings

theorem FlatInvariant.described {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x p, (x, p) ∈ live → ∀ o w a w', env.lookup x = some (o, w) → aenv.lookup x = some a →
      projectVal w p = some w' → Describes gamma hs.heap (a.atPath p) w' :=
  inv.toInvariant.described

theorem FlatInvariant.named {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) :
    ∀ x o w a, env.lookup x = some (o, w) → aenv.lookup x = some a →
      ∀ q c, immutablePath q = true → ArrayAt hs.heap w q c → named gamma (a.cellsAt q) c :=
  inv.toInvariant.named

theorem FlatInvariant.separating {declarations : List Decl} {vs : ValueSemantics.State} {hs : InPlaceSemantics.State} {env : List (Var × Observation × Value)} {live : Live} {aenv : Env Abstract} {tenv : Env Ty} {escapes : List Origin} {gamma : Naming} (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma) : Separating gamma := inv.toInvariant.separating

/-- The current heap value of every runtime reference remains allocated.
The binding need not occur in the live-use set. -/
theorem FlatInvariant.binding_allocated
    (inv : FlatInvariant declarations vs hs env live aenv tenv escapes gamma)
    (binding : env.lookup x = some (observation, .ref address)) :
    address < hs.heap.size := by
  obtain ⟨ty, _, _, typed⟩ := inv.bindingsTyped x observation (.ref address) binding
  obtain ⟨depth, current, footprint, represented, _⟩ := typed
  cases represented with
  | ref allocated _ => exact (Array.getElem?_eq_some_iff.mp allocated).1

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
    toInvariant := invariant_initial fuel live escapes emptyNaming emptyNaming_separating
    links := rfl
    abstractKeys := rfl
    typeKeys := rfl
    types := ?_
    abstractShapes := ?_
    bindingsTyped := ?_
    tags := ?_
    chains := ?_
    liveTyped := ?_
    namingBound := emptyNaming_bound 0
    observers := ⟨[], RepresentsMany.nil⟩
  }
  · intro x ty present
    simp at present
  · intro x ty abstract present
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
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      exact ih at_p

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
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_snoc
    | some t' =>
      simp [h] at at_snoc
      exact ih at_snoc

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
    cases step <;> cases o <;> simp [projectObs] at projected ⊢
    rename_i i' os
    cases h : os[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      exact ih projected

theorem projectVal_snoc_inv {w w' : Value} {p : Path} {i : Nat}
    (projected : projectVal w (p ++ [.field i]) = some w') :
    ∃ ws, projectVal w p = some (.record ws) ∧ ws[i]? = some w' := by
  induction p generalizing w with
  | nil =>
    cases w <;> simp [projectVal] at projected
    rename_i ws
    cases h : ws[i]? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      subst projected
      exact ⟨ws, rfl, h⟩
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at projected ⊢
    rename_i i' ws
    cases h : ws[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      exact ih projected

theorem projectObs_snoc {o o' : Observation} {os : List Observation} {p : Path} {i : Nat}
    (projected : projectObs o p = some (.record os)) (field : os[i]? = some o') :
    projectObs o (p ++ [.field i]) = some o' := by
  induction p generalizing o with
  | nil =>
    simp [projectObs] at projected
    subst projected
    simp [projectObs, field]
  | cons step rest ih =>
    cases step <;> cases o <;> simp [projectObs] at projected ⊢
    rename_i i' os'
    cases h : os'[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      exact ih projected

theorem projectVal_snoc {w w' : Value} {ws : List Value} {p : Path} {i : Nat}
    (projected : projectVal w p = some (.record ws)) (field : ws[i]? = some w') :
    projectVal w (p ++ [.field i]) = some w' := by
  induction p generalizing w with
  | nil =>
    simp [projectVal] at projected
    subst projected
    simp [projectVal, field]
  | cons step rest ih =>
    cases step <;> cases w <;> simp [projectVal] at projected ⊢
    rename_i i' ws'
    cases h : ws'[i']? with
    | none => simp [h] at projected
    | some x =>
      simp [h] at projected
      exact ih projected

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

theorem heap_atom_of_root {renv : Env Value} {a : Atom} {k : Var} {p : Path} {w w' : Value}
    (root : atomRoot a = some (k, p)) (found : renv.lookup k = some w)
    (projected : projectVal w p = some w') :
    InPlaceSemantics.atom renv a = .ok w' := by
  induction a generalizing k p w' with
  | int n => simp [atomRoot] at root
  | var v =>
    simp [atomRoot] at root
    obtain ⟨rfl, rfl⟩ := root
    simp [projectVal] at projected
    subst projected
    simp [InPlaceSemantics.atom, lookup, found]
  | field a i ih =>
    obtain ⟨p0, inner, rfl⟩ := atomRoot_field root
    obtain ⟨ws, innerProjected, at_i⟩ := projectVal_snoc_inv projected
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
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      cases flat with
      | record _ fields => exact ih (fields t' (List.mem_of_getElem? h)) at_p

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
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
      · rw [atPath_bottom, atPath_bottom, atPath_bottom]
      · obtain ⟨a', at_i, shape'⟩ := flatAbstract_record_field len fields h
        simp only [List.cons_append, Abstract.atPath, at_i, Option.getD_some]
        exact ih shape' at_p

theorem flatAbstract_atPath {tk ty : Ty} {a : Abstract} {p : Path}
    (shape : FlatAbstract tk a) (at_p : tyAt tk p = some ty) : FlatAbstract ty (a.atPath p) := by
  induction p generalizing tk a with
  | nil =>
    simp [tyAt] at at_p
    subst at_p
    simpa [Abstract.atPath] using shape
  | cons step rest ih =>
    cases step <;> cases tk <;> simp [tyAt] at at_p
    rename_i i' ts
    cases h : ts[i']? with
    | none => simp [h] at at_p
    | some t' =>
      simp [h] at at_p
      rcases flatAbstract_record shape with rfl | ⟨as, rfl, len, fields⟩
      · rw [atPath_bottom]; exact .bottom _
      · obtain ⟨a', at_i, shape'⟩ := flatAbstract_record_field len fields h
        simp only [Abstract.atPath, at_i, Option.getD_some]
        exact ih shape' at_p

end Ownership.FlatFragment.Fields
