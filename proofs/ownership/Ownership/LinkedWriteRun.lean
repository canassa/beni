import Ownership.LinkedWriteValid

/-! A linked write on a state with valid links runs to completion, and its
post-state is the one the flat fragment needs (#169).

* It succeeds: `spliceUp` climbs to smaller addresses and `refreshDown`
  descends to larger ones, so the fuel `size + 1` suffices for both
  (`spliceUp_success`, `refreshDown_success`, `writeLinked_success`).
* Only the heap and the write counter change.
* The written array holds the stored list after the splice and the refresh
  (`writeLinked_root`): the splice makes every link on the path from the
  written array to the top consistent (`spliceUp_chain`), and the refresh
  recomputes those links from the top.
* Every element of an array in the written array's link component is an
  element of the stored list or of an old array of that component
  (`writeLinked_contents`).
* A write to an array that no link names is a plain write
  (`writeCounted_unlinked_run`). -/

namespace Ownership.LinkedWriteRun

open InPlaceSemantics Soundness LinkedWriteFrame LinkedWriteValid

/-- Running a bind whose first action succeeds. -/
theorem run_bind_ok {α β : Type} {action : M α} {next : α → M β} {pre middle : State} {value : α}
    (first : action.run pre = .ok (value, middle)) :
    (action >>= next).run pre = (next value).run middle := by
  change (action pre >>= fun (a, s) => next a s) = (next value) middle
  have same : action pre = .ok (value, middle) := first
  rw [same]
  rfl

theorem array_ok {s : State} {c : Nat} {xs : List Value} (lookup : s.heap[c]? = some xs) :
    (array c).run s = .ok (xs, s) := by
  rw [array_run, lookup]

theorem write_ok (s : State) {c : Nat} (lt : c < s.heap.size) (xs : List Value) :
    (write c xs).run s = .ok (.ref c, {s with heap := s.heap.set! c xs}) := by
  rw [write_run, if_neg (by omega)]

theorem lookup_exists {heap : Array (List Value)} {c : Nat} (lt : c < heap.size) :
    ∃ xs, heap[c]? = some xs :=
  ⟨heap[c], Array.getElem?_eq_getElem lt⟩

/-! ## Success -/

/-- The splice succeeds from an address below its fuel, and changes only the
heap; its top is at or below the start. -/
theorem spliceUp_success {links : Links} {size : Nat} (shape : Shape links size) :
    ∀ (depth : Nat) {c : Nat} {cur : State}, c < depth → c < size → cur.links = links →
      cur.heap.size = size →
      ∃ r h, (spliceUp depth c).run cur = .ok (r, {cur with heap := h}) ∧ h.size = size ∧ r ≤ c := by
  intro depth
  induction depth with
  | zero =>
    intro c cur lt
    omega
  | succ depth ih =>
    intro c cur lt bound same sizeEq
    change ∃ r h, ((match cur.links.find? (·.1 == c) with
      | none => pure c
      | some (_, source, front) => do
        let base ← array source
        let xs ← array c
        let _ ← write source
          (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))
        spliceUp depth source) : M Nat).run cur = .ok (r, {cur with heap := h}) ∧ h.size = size ∧ r ≤ c
    cases found : cur.links.find? (·.1 == c) with
    | none =>
      simp only [found]
      exact ⟨c, cur.heap, rfl, sizeEq, Nat.le_refl c⟩
    | some edge =>
      rcases edge with ⟨view, source, front⟩
      have view_eq : view = c := by
        have test := List.find?_some found
        simpa using test
      subst view_eq
      have member : (view, source, front) ∈ links := same ▸ List.mem_of_find?_eq_some found
      obtain ⟨sourceLt, viewLt⟩ := shape.bounded _ _ _ member
      simp only [found]
      obtain ⟨base, baseLookup⟩ := lookup_exists (heap := cur.heap) (c := source) (by omega)
      obtain ⟨xs, xsLookup⟩ := lookup_exists (heap := cur.heap) (c := view) (by omega)
      obtain ⟨r, h, rest, hSize, below⟩ := ih (c := source) (cur := {cur with heap := cur.heap.set! source (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))})
        (by omega) (by omega) same (by simp [sizeEq])
      refine ⟨r, h, ?_, hSize, by omega⟩
      rw [run_bind_ok (array_ok baseLookup)]
      try dsimp only
      rw [run_bind_ok (array_ok xsLookup)]
      try dsimp only
      rw [run_bind_ok (write_ok cur (by omega) _)]
      exact rest

/-- The refresh succeeds from an address whose distance to the heap's end is
below its fuel, and changes only the heap. -/
theorem refreshDown_success {links : Links} {size : Nat} (shape : Shape links size) :
    ∀ (depth : Nat) {c : Nat} {cur : State}, size - c < depth → c < size → cur.links = links →
      cur.heap.size = size →
      ∃ h, (refreshDown depth c).run cur = .ok ((), {cur with heap := h}) ∧ h.size = size := by
  intro depth
  induction depth with
  | zero =>
    intro c cur lt
    omega
  | succ depth ih =>
    intro c cur lt bound same sizeEq
    have loop : ∀ (items : Links) (cur : State), cur.links = links → cur.heap.size = size →
        (∀ e ∈ items, e ∈ links) →
        ∃ h, (forIn items () (refreshStep depth c)).run cur = .ok ((), {cur with heap := h}) ∧
          h.size = size := by
      intro items
      induction items with
      | nil =>
        intro cur _ sizeEq _
        exact ⟨cur.heap, rfl, sizeEq⟩
      | cons e rest ihRest =>
        intro cur same sizeEq sub
        rcases e with ⟨v, s, f⟩
        have member : (v, s, f) ∈ links := sub _ (by simp)
        have subRest : ∀ e ∈ rest, e ∈ links := fun e m => sub e (by simp [m])
        rw [List.forIn_cons]
        by_cases sameC : s = c
        · subst sameC
          obtain ⟨sLt, vLt⟩ := shape.bounded _ _ _ member
          obtain ⟨xs, xsLookup⟩ := lookup_exists (heap := cur.heap) (c := s) (by omega)
          obtain ⟨h1, refreshRun, h1Size⟩ := ih (c := v)
            (cur := {cur with heap := cur.heap.set! v (viewOf f xs)}) (by omega) vLt same (by simp [sizeEq])
          have stepRun : (refreshStep depth s (v, s, f) ()).run cur =
              .ok (.yield (), {cur with heap := h1}) := by
            simp only [refreshStep, beq_self_eq_true, if_true]
            rw [run_bind_ok (array_ok xsLookup)]
            try dsimp only
            rw [run_bind_ok (write_ok cur (by omega) _)]
            try dsimp only
            rw [run_bind_ok refreshRun]
            rfl
          obtain ⟨h2, restRun, h2Size⟩ := ihRest {cur with heap := h1} same h1Size subRest
          refine ⟨h2, ?_, h2Size⟩
          rw [run_bind_ok stepRun]
          exact restRun
        · have stepRun : (refreshStep depth c (v, s, f) ()).run cur = .ok (.yield (), cur) := by
            have different : (s == c) = false := by simp [sameC]
            simp only [refreshStep, different, Bool.false_eq_true, if_false]
            rfl
          obtain ⟨h2, restRun, h2Size⟩ := ihRest cur same sizeEq subRest
          refine ⟨h2, ?_, h2Size⟩
          rw [run_bind_ok stepRun]
          exact restRun
    change ∃ h, ((forIn cur.links () (refreshStep depth c) >>= fun _ => pure ()) :
      M Unit).run cur = .ok ((), {cur with heap := h}) ∧ h.size = size
    obtain ⟨h, loopRun, hSize⟩ := loop cur.links cur same sizeEq (fun e m => same ▸ m)
    exact ⟨h, by rw [run_bind_ok loopRun]; rfl, hSize⟩

/-- A linked write of an allocated array succeeds on a state with valid
links, and changes only the heap. -/
theorem writeLinked_success {s : State} (valid : LinksValid s) {c : Nat} (lt : c < s.heap.size)
    (xs : List Value) :
    ∃ h, (writeLinked c xs).run s = .ok (.ref c, {s with heap := h}) ∧ h.size = s.heap.size := by
  have shape := Shape.of_valid valid
  change ∃ h, ((write c xs) >>= fun r => do
    let s ← get
    if s.links.isEmpty then return r
    let ancestor ← spliceUp (s.heap.size + 1) c
    refreshDown (s.heap.size + 1) ancestor
    pure r).run s = .ok (.ref c, {s with heap := h}) ∧ h.size = s.heap.size
  rw [run_bind_ok (write_ok s lt xs)]
  change ∃ h, ((if s.links.isEmpty then pure (Value.ref c) else do
    let ancestor ← spliceUp ((s.heap.set! c xs).size + 1) c
    refreshDown ((s.heap.set! c xs).size + 1) ancestor
    pure (Value.ref c)) : M Value).run {s with heap := s.heap.set! c xs} =
      .ok (.ref c, {s with heap := h}) ∧ h.size = s.heap.size
  have sizeSet : (s.heap.set! c xs).size = s.heap.size := by simp
  by_cases empty : s.links.isEmpty
  · rw [if_pos empty]
    exact ⟨s.heap.set! c xs, rfl, sizeSet⟩
  · rw [if_neg empty]
    obtain ⟨r, h1, spliceRun, h1Size, rLe⟩ := spliceUp_success shape ((s.heap.set! c xs).size + 1) (c := c)
      (cur := {s with heap := s.heap.set! c xs}) (by omega) lt rfl sizeSet
    obtain ⟨h2, refreshRun, h2Size⟩ := refreshDown_success shape ((s.heap.set! c xs).size + 1) (c := r)
      (cur := {s with heap := h1}) (by omega) (by omega) rfl h1Size
    refine ⟨h2, ?_, h2Size⟩
    rw [run_bind_ok spliceRun]
    try dsimp only
    rw [run_bind_ok refreshRun]
    rfl

/-! ## The written array keeps the stored list -/

/-- A view of a nonempty source, written back with the view's contents in
place of the old ones, holds those contents again. -/
theorem viewOf_spliced (front : Bool) {base : List Value} (nonempty : base ≠ []) (xs : List Value) :
    viewOf front (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1)) = xs := by
  have pos : 0 < base.length := List.length_pos_iff.mpr nonempty
  cases front with
  | true =>
    simp only [viewOf, if_true]
    have one : (base.take 1).length = 1 := by simp; omega
    rw [List.drop_append, List.drop_eq_nil_of_le (by omega), one]
    simp
  | false =>
    simp only [viewOf, Bool.false_eq_true, if_false]
    have one : (base.drop (base.length - 1)).length = 1 := by simp; omega
    obtain ⟨last, lastEq⟩ : ∃ last, base.drop (base.length - 1) = [last] := by
      cases h : base.drop (base.length - 1) with
      | nil => rw [h] at one; simp at one
      | cons a rest =>
        rw [h] at one
        cases rest with
        | nil => exact ⟨a, rfl⟩
        | cons _ _ => simp at one
    rw [lastEq, List.dropLast_concat]

/-- After the splice from `x`: its top is above `x`, the arrays at and above
`x`'s address are untouched, and every link on the path from `x` to the top
holds its source's suffix or prefix. -/
theorem spliceUp_chain {orig : State} (valid : LinksValid orig) (depth : Nat) :
    ∀ {x : Nat} {cur post : State} {r : Nat},
      cur.links = orig.links → cur.heap.size = orig.heap.size →
      (∀ y, ¬ Below orig.links x y → cur.heap[y]? = orig.heap[y]?) →
      (spliceUp depth x).run cur = .ok (r, post) →
      Below orig.links r x ∧ post.links = orig.links ∧ post.heap.size = orig.heap.size ∧
      (∀ y, x ≤ y → post.heap[y]? = cur.heap[y]?) ∧
      (∀ v s f, (v, s, f) ∈ orig.links → Below orig.links v x →
        ∃ src, post.heap[s]? = some src ∧ post.heap[v]? = some (viewOf f src)) := by
  have shape := Shape.of_valid valid
  induction depth with
  | zero =>
    intro x cur post r _ _ _ run
    change Except.error "view chain exhausted fuel" = Except.ok (r, post) at run
    contradiction
  | succ depth ih =>
    intro x cur post r same size outside run
    change ((match cur.links.find? (·.1 == x) with
      | none => pure x
      | some (_, source, front) => do
        let base ← array source
        let xs ← array x
        let _ ← write source
          (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))
        spliceUp depth source) : M Nat).run cur = .ok (r, post) at run
    rw [same] at run
    cases found : orig.links.find? (·.1 == x) with
    | none =>
      simp only [found] at run
      change Except.ok (x, cur) = Except.ok (r, post) at run
      cases run
      refine ⟨.refl, same, size, fun _ _ => rfl, ?_⟩
      intro v s f member below
      cases below with
      | refl =>
        have := List.find?_eq_none.mp found _ member
        simp at this
      | @step s' _ f' _ member' =>
        have := List.find?_eq_none.mp found _ member'
        simp at this
    | some edge =>
      rcases edge with ⟨view, source, front⟩
      have view_eq : view = x := by
        have test := List.find?_some found
        simpa using test
      subst view_eq
      have member : (view, source, front) ∈ orig.links := List.mem_of_find?_eq_some found
      obtain ⟨sourceLt, viewLt⟩ := shape.bounded _ _ _ member
      simp only [found] at run
      obtain ⟨base, afterBase, readBase, restBase⟩ := bind_success run
      obtain ⟨eqBase, baseLookup⟩ := array_success readBase
      subst afterBase
      obtain ⟨xs, afterXs, readXs, restXs⟩ := bind_success restBase
      obtain ⟨eqXs, xsLookup⟩ := array_success readXs
      subst afterXs
      obtain ⟨written, middle, writeRun, rest⟩ := bind_success restXs
      rw [write_run] at writeRun
      split at writeRun
      · contradiction
      · cases writeRun
        have sourceOutside : ¬ Below orig.links view source := by
          intro below
          have := below_ge shape below
          omega
        have baseOrig : orig.heap[source]? = some base := by
          rw [← outside source sourceOutside]
          exact baseLookup
        obtain ⟨origSource, origSourceLookup, origNonempty⟩ := valid.sources _ _ _ member
        have baseNonempty : base ≠ [] := by
          rw [origSourceLookup] at baseOrig
          rw [← Option.some.inj baseOrig]
          exact origNonempty
        have viewBelow : Below orig.links source view := .step .refl member
        obtain ⟨belowR, links', size', untouched, chain⟩ := ih (x := source)
          (cur := {cur with heap := cur.heap.set! source (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))})
          same (by simpa using size)
          (by
            intro y notBelow
            have neSource : y ≠ source := fun eq => notBelow (eq ▸ .refl)
            have notBelowView : ¬ Below orig.links view y := fun below =>
              notBelow (below_trans viewBelow below)
            rw [HeapProof.lookup_set_other cur.heap source _ neSource]
            exact outside y notBelowView)
          rest
        have sourceLt' : source < cur.heap.size := by omega
        have postView : post.heap[view]? = some xs := by
          rw [untouched view (by omega), HeapProof.lookup_set_other cur.heap source _ (by omega)]
          exact xsLookup
        have postSource : post.heap[source]? =
            some (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1)) := by
          rw [untouched source (Nat.le_refl _)]
          simp [sourceLt']
        refine ⟨.step belowR member, links', size', ?_, ?_⟩
        · intro y ge
          rw [untouched y (by omega), HeapProof.lookup_set_other cur.heap source _ (by omega)]
        · intro v s f memberV belowV
          by_cases same' : v = view
          · subst same'
            obtain ⟨rfl, rfl⟩ := source_unique shape.unique memberV member
            refine ⟨_, postSource, ?_⟩
            rw [postView, viewOf_spliced f baseNonempty xs]
          · exact chain v s f memberV (below_parent shape belowV (Ne.symm same') member)

/-- The written array holds the stored list after a successful linked write. -/
theorem writeLinked_root {s post : State} (valid : LinksValid s) {c : Nat} {xs : List Value} {r : Value}
    (run : (writeLinked c xs).run s = .ok (r, post)) : post.heap[c]? = some xs := by
  change ((write c xs) >>= fun r => do
    let s ← get
    if s.links.isEmpty then return r
    let ancestor ← spliceUp (s.heap.size + 1) c
    refreshDown (s.heap.size + 1) ancestor
    pure r).run s = .ok (r, post) at run
  obtain ⟨written, afterWrite, writeRun, rest⟩ := bind_success run
  rw [write_run] at writeRun
  split at writeRun
  · contradiction
  · rename_i inRange
    have cLt : c < s.heap.size := by omega
    cases writeRun
    have afterLookup : (s.heap.set! c xs)[c]? = some xs := by simp [cLt]
    change ((if s.links.isEmpty then pure (Value.ref c) else do
      let ancestor ← spliceUp ((s.heap.set! c xs).size + 1) c
      refreshDown ((s.heap.set! c xs).size + 1) ancestor
      pure (Value.ref c)) : M Value).run {s with heap := s.heap.set! c xs} = .ok (r, post) at rest
    split at rest
    · change Except.ok (Value.ref c, {s with heap := s.heap.set! c xs}) = Except.ok (r, post) at rest
      cases rest
      exact afterLookup
    · obtain ⟨top, afterSplice, spliceRun, restSplice⟩ := bind_success rest
      obtain ⟨belowTop, sl, ss, untouched, chain⟩ :=
        spliceUp_chain valid _ (x := c) (cur := {s with heap := s.heap.set! c xs}) rfl (by simp)
          (by
            intro y notBelow
            have ne : y ≠ c := fun eq => notBelow (eq ▸ .refl)
            exact HeapProof.lookup_set_other _ _ _ ne)
          spliceRun
      obtain ⟨finished, afterRefresh, refreshRun, finishRun⟩ := bind_success restSplice
      change Except.ok (Value.ref c, afterRefresh) = Except.ok (r, post) at finishRun
      cases finishRun
      have shape := Shape.of_valid valid
      obtain ⟨_, _, consistent, unchangedTop⟩ := refreshDown_valid shape _ (c := top) sl ss refreshRun
      have down : ∀ y, Below s.links top y → Below s.links y c →
          post.heap[y]? = afterSplice.heap[y]? := by
        intro y below
        induction below with
        | refl =>
          intro _
          exact unchangedTop top (fun _ => rfl)
        | @step src v f belowSrc member ihSrc =>
          intro belowV
          have belowSrcC : Below s.links src c := below_trans (.step .refl member) belowV
          obtain ⟨now, nowSource, nowView⟩ := consistent v src f member belowSrc
          obtain ⟨was, wasSource, wasView⟩ := chain v src f member belowV
          rw [ihSrc belowSrcC, wasSource] at nowSource
          cases Option.some.inj nowSource
          rw [nowView, wasView]
      rw [down c belowTop .refl, untouched c (Nat.le_refl _)]
      exact afterLookup

/-! ## Where the contents of the component come from -/

/-- Every element of an array in `root`'s link component is an element of
the stored list or of an old array of that component. -/
def ComponentFrom (links : Links) (root : Nat) (stored : List Value) (orig cur : State) : Prop :=
  ∀ a ys y, cur.heap[a]? = some ys → y ∈ ys → LinkConnected links root a →
    y ∈ stored ∨ ∃ d zs, LinkConnected links root d ∧ orig.heap[d]? = some zs ∧ y ∈ zs

theorem componentFrom_write {links : Links} {root : Nat} {stored : List Value} {orig cur : State}
    (sourced : ComponentFrom links root stored orig cur) {target : Nat} {new : List Value}
    (lt : target < cur.heap.size)
    (elements : ∀ y ∈ new, ∃ a ys, LinkConnected links root a ∧ cur.heap[a]? = some ys ∧ y ∈ ys) :
    ComponentFrom links root stored orig {cur with heap := cur.heap.set! target new} := by
  intro a ys y lookup member connected
  by_cases same : a = target
  · subst same
    have eq := set_self_eq lt lookup
    subst eq
    obtain ⟨a', ys', connected', lookup', member'⟩ := elements y member
    exact sourced a' ys' y lookup' member' connected'
  · rw [HeapProof.lookup_set_other cur.heap target new same] at lookup
    exact sourced a ys y lookup member connected

theorem mem_of_mem_viewOf {front : Bool} {xs : List Value} {y : Value} (member : y ∈ viewOf front xs) :
    y ∈ xs := by
  unfold viewOf at member
  split at member
  · exact List.mem_of_mem_drop member
  · exact (List.dropLast_sublist _).subset member

theorem spliceUp_from {links : Links} {root : Nat} {stored : List Value} {orig : State} (depth : Nat) :
    ∀ {x : Nat} {cur post : State} {r : Nat}, LinkConnected links root x → cur.links = links →
      ComponentFrom links root stored orig cur → (spliceUp depth x).run cur = .ok (r, post) →
      ComponentFrom links root stored orig post := by
  induction depth with
  | zero =>
    intro x cur post r _ _ _ run
    change Except.error "view chain exhausted fuel" = Except.ok (r, post) at run
    contradiction
  | succ depth ih =>
    intro x cur post r connected same sourced run
    change ((match cur.links.find? (·.1 == x) with
      | none => pure x
      | some (_, source, front) => do
        let base ← array source
        let xs ← array x
        let _ ← write source
          (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))
        spliceUp depth source) : M Nat).run cur = .ok (r, post) at run
    rw [same] at run
    cases found : links.find? (·.1 == x) with
    | none =>
      simp only [found] at run
      change Except.ok (x, cur) = Except.ok (r, post) at run
      cases run
      exact sourced
    | some edge =>
      rcases edge with ⟨view, source, front⟩
      have view_eq : view = x := by
        have test := List.find?_some found
        simpa using test
      subst view_eq
      have member : (view, source, front) ∈ links := List.mem_of_find?_eq_some found
      have sourceConnected : LinkConnected links root source := connected.trans (LinkConnected.edge member)
      simp only [found] at run
      obtain ⟨base, afterBase, readBase, restBase⟩ := bind_success run
      obtain ⟨eqBase, baseLookup⟩ := array_success readBase
      subst afterBase
      obtain ⟨xs, afterXs, readXs, restXs⟩ := bind_success restBase
      obtain ⟨eqXs, xsLookup⟩ := array_success readXs
      subst afterXs
      obtain ⟨written, middle, writeRun, rest⟩ := bind_success restXs
      rw [write_run] at writeRun
      split at writeRun
      · contradiction
      · rename_i inRange
        cases writeRun
        refine ih (cur := {cur with heap := cur.heap.set! source (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))}) sourceConnected same ?_ rest
        refine componentFrom_write sourced (by omega) ?_
        intro y member'
        split at member'
        · rcases List.mem_append.mp member' with inBase | inXs
          · exact ⟨source, base, sourceConnected, baseLookup, List.mem_of_mem_take inBase⟩
          · exact ⟨view, xs, connected, xsLookup, inXs⟩
        · rcases List.mem_append.mp member' with inXs | inBase
          · exact ⟨view, xs, connected, xsLookup, inXs⟩
          · exact ⟨source, base, sourceConnected, baseLookup, List.mem_of_mem_drop inBase⟩

theorem refreshDown_from {links : Links} {root : Nat} {stored : List Value} {orig : State} (depth : Nat) :
    ∀ {c : Nat} {cur post : State} {u : Unit}, LinkConnected links root c → cur.links = links →
      ComponentFrom links root stored orig cur → (refreshDown depth c).run cur = .ok (u, post) →
      ComponentFrom links root stored orig post := by
  induction depth with
  | zero =>
    intro c cur post u _ _ _ run
    change Except.error "view chain exhausted fuel" = Except.ok (u, post) at run
    contradiction
  | succ depth ih =>
    intro c cur post u connected same sourced run
    change ((forIn cur.links () (refreshStep depth c) >>= fun _ => pure ()) :
      M Unit).run cur = .ok (u, post) at run
    have loop : ∀ (items : Links) {cur post : State} {u : Unit}, cur.links = links →
        (∀ e ∈ items, e ∈ links) → ComponentFrom links root stored orig cur →
        (forIn items () (refreshStep depth c)).run cur = .ok (u, post) →
        ComponentFrom links root stored orig post := by
      intro items
      induction items with
      | nil =>
        intro cur post u _ _ sourced run
        simp only [List.forIn_nil] at run
        change Except.ok ((), cur) = Except.ok (u, post) at run
        cases run
        exact sourced
      | cons head rest ihRest =>
        rcases head with ⟨v, s, f⟩
        intro cur post u same sub sourced run
        have memberLinks : (v, s, f) ∈ links := sub _ (by simp)
        have subRest : ∀ e ∈ rest, e ∈ links := fun e h => sub e (by simp [h])
        rw [List.forIn_cons] at run
        obtain ⟨stepResult, middle, stepRun, restRun⟩ := bind_success run
        by_cases sameC : s = c
        · rw [sameC] at memberLinks
          have viewConnected : LinkConnected links root v :=
            connected.trans (LinkConnected.symm (LinkConnected.edge memberLinks))
          simp only [refreshStep, sameC, beq_self_eq_true, if_true] at stepRun
          obtain ⟨xs, afterXs, readXs, rest₁⟩ := bind_success stepRun
          obtain ⟨eqXs, xsLookup⟩ := array_success readXs
          subst afterXs
          obtain ⟨w, mid₁, writeRun, rest₂⟩ := bind_success rest₁
          rw [write_run] at writeRun
          split at writeRun
          · contradiction
          · rename_i inRange
            cases writeRun
            obtain ⟨u₂, mid₂, refreshRun, rest₃⟩ := bind_success rest₂
            change Except.ok (ForInStep.yield (), mid₂) = Except.ok (stepResult, middle) at rest₃
            have eqStep : stepResult = ForInStep.yield () := by
              cases rest₃
              rfl
            have eqMiddle : middle = mid₂ := by
              cases rest₃
              rfl
            subst stepResult
            subst middle
            change (forIn rest () (refreshStep depth c)).run mid₂ = .ok (u, post) at restRun
            have written : ComponentFrom links root stored orig
                {cur with heap := cur.heap.set! v (viewOf f xs)} :=
              componentFrom_write sourced (by omega)
                (fun y member => ⟨c, xs, connected, xsLookup, mem_of_mem_viewOf member⟩)
            have refreshed := ih (cur := {cur with heap := cur.heap.set! v (viewOf f xs)}) viewConnected same
              written refreshRun
            have links₂ : mid₂.links = links := by
              have shapeFrame := refreshDown_preserves depth viewConnected
                {cur with heap := cur.heap.set! v (viewOf f xs)} _ _ same refreshRun
              exact shapeFrame.links_eq
            exact ihRest links₂ subRest refreshed restRun
        · have ne : (s == c) = false := by simp [sameC]
          simp only [refreshStep, ne, Bool.false_eq_true, if_false] at stepRun
          change Except.ok (ForInStep.yield (), cur) = Except.ok (stepResult, middle) at stepRun
          cases stepRun
          change (forIn rest () (refreshStep depth c)).run cur = .ok (u, post) at restRun
          exact ihRest same subRest sourced restRun
    obtain ⟨u', middle, loopRun, finish⟩ := bind_success run
    change Except.ok ((), middle) = Except.ok (u, post) at finish
    cases finish
    exact loop cur.links same (fun e m => same ▸ m) sourced loopRun

/-- After a successful linked write, every element of an array in the
written array's link component is an element of the stored list or of an
old array of that component. -/
theorem writeLinked_contents {s post : State} {c : Nat} {xs : List Value} {r : Value}
    (run : (writeLinked c xs).run s = .ok (r, post)) :
    ComponentFrom s.links c xs s post := by
  change ((write c xs) >>= fun r => do
    let s ← get
    if s.links.isEmpty then return r
    let ancestor ← spliceUp (s.heap.size + 1) c
    refreshDown (s.heap.size + 1) ancestor
    pure r).run s = .ok (r, post) at run
  obtain ⟨written, afterWrite, writeRun, rest⟩ := bind_success run
  rw [write_run] at writeRun
  split at writeRun
  · contradiction
  · rename_i inRange
    cases writeRun
    have first : ComponentFrom s.links c xs s {s with heap := s.heap.set! c xs} := by
      intro a ys y lookup member _
      by_cases same : a = c
      · subst same
        have eq := set_self_eq (by omega) lookup
        subst eq
        exact Or.inl member
      · rw [HeapProof.lookup_set_other s.heap c xs same] at lookup
        exact Or.inr ⟨a, ys, by assumption, lookup, member⟩
    change ((if s.links.isEmpty then pure (Value.ref c) else do
      let ancestor ← spliceUp ((s.heap.set! c xs).size + 1) c
      refreshDown ((s.heap.set! c xs).size + 1) ancestor
      pure (Value.ref c)) : M Value).run {s with heap := s.heap.set! c xs} = .ok (r, post) at rest
    split at rest
    · change Except.ok (Value.ref c, {s with heap := s.heap.set! c xs}) = Except.ok (r, post) at rest
      cases rest
      exact first
    · obtain ⟨top, afterSplice, spliceRun, restSplice⟩ := bind_success rest
      obtain ⟨spliceFrame, topConnected⟩ := spliceUp_preserves _ (LinkConnected.refl c)
        (pre := {s with heap := s.heap.set! c xs}) rfl spliceRun
      have spliced := spliceUp_from (links := s.links) (root := c) (stored := xs) (orig := s) _
        (cur := {s with heap := s.heap.set! c xs}) (LinkConnected.refl c) rfl first spliceRun
      obtain ⟨finished, afterRefresh, refreshRun, finishRun⟩ := bind_success restSplice
      change Except.ok (Value.ref c, afterRefresh) = Except.ok (r, post) at finishRun
      cases finishRun
      exact refreshDown_from _ topConnected spliceFrame.links_eq spliced refreshRun

/-! ## An array that no link names -/

theorem spliceUp_unlinked {depth c : Nat} {cur : State}
    (unlinked : ∀ v src f, (v, src, f) ∈ cur.links → v ≠ c) :
    (spliceUp (depth + 1) c).run cur = .ok (c, cur) := by
  change ((match cur.links.find? (·.1 == c) with
    | none => pure c
    | some (_, source, front) => do
      let base ← array source
      let xs ← array c
      let _ ← write source
        (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))
      spliceUp depth source) : M Nat).run cur = .ok (c, cur)
  have found : cur.links.find? (·.1 == c) = none := by
    apply List.find?_eq_none.mpr
    intro e member
    rcases e with ⟨v, src, f⟩
    simp [unlinked v src f member]
  simp only [found]
  rfl

theorem refreshDown_unlinked {depth c : Nat} {cur : State}
    (unlinked : ∀ v src f, (v, src, f) ∈ cur.links → src ≠ c) :
    (refreshDown (depth + 1) c).run cur = .ok ((), cur) := by
  change ((forIn cur.links () (refreshStep depth c) >>= fun _ => pure ()) :
    M Unit).run cur = .ok ((), cur)
  have loop : ∀ (items : Links), (∀ e ∈ items, e ∈ cur.links) →
      (forIn items () (refreshStep depth c)).run cur = .ok ((), cur) := by
    intro items
    induction items with
    | nil => intro _; rfl
    | cons e rest ih =>
      intro sub
      rcases e with ⟨v, src, f⟩
      have different : (src == c) = false := by
        simp [unlinked v src f (sub _ (by simp))]
      have stepRun : (refreshStep depth c (v, src, f) ()).run cur = .ok (.yield (), cur) := by
        simp only [refreshStep, different, Bool.false_eq_true, if_false]
        rfl
      rw [List.forIn_cons, run_bind_ok stepRun]
      exact ih (fun e m => sub e (by simp [m]))
  rw [run_bind_ok (loop cur.links (fun _ m => m))]
  rfl

theorem writeLinked_unlinked (s : State) {c : Nat} (lt : c < s.heap.size) (xs : List Value)
    (unlinked : ∀ v src f, (v, src, f) ∈ s.links → v ≠ c ∧ src ≠ c) :
    (writeLinked c xs).run s = .ok (.ref c, {s with heap := s.heap.set! c xs}) := by
  change ((write c xs) >>= fun r => do
    let s ← get
    if s.links.isEmpty then return r
    let ancestor ← spliceUp (s.heap.size + 1) c
    refreshDown (s.heap.size + 1) ancestor
    pure r).run s = _
  rw [run_bind_ok (write_ok s lt xs)]
  change ((if s.links.isEmpty then pure (Value.ref c) else do
    let ancestor ← spliceUp ((s.heap.set! c xs).size + 1) c
    refreshDown ((s.heap.set! c xs).size + 1) ancestor
    pure (Value.ref c)) : M Value).run {s with heap := s.heap.set! c xs} = _
  by_cases empty : s.links.isEmpty
  · rw [if_pos empty]
    rfl
  · rw [if_neg empty]
    rw [run_bind_ok (spliceUp_unlinked (cur := {s with heap := s.heap.set! c xs})
      (fun v src f member => (unlinked v src f member).1))]
    try dsimp only
    rw [run_bind_ok (refreshDown_unlinked (cur := {s with heap := s.heap.set! c xs})
      (fun v src f member => (unlinked v src f member).2))]
    rfl

/-! ## The counted write -/

theorem countWrite_run (s : State) : countWrite.run s = .ok ((), {s with writes := s.writes + 1}) := rfl

/-- The counted write: the run of the linked write from the state with the
counter already moved. -/
theorem writeCounted_run (s : State) {root : Nat} {old stored : List Value}
    (lookup : s.heap[root]? = some old) :
    (writeCounted root stored).run s =
      (writeLinked root stored).run {s with writes := if old == stored then s.writes else s.writes + 1} := by
  unfold writeCounted
  rw [run_bind_ok (array_ok lookup)]
  try dsimp only
  by_cases equal : (old == stored) = true
  · simp only [equal, Bool.not_true, Bool.false_eq_true, if_false, if_true]
    rw [run_bind_ok (show (pure () : M Unit).run s = .ok ((), s) from rfl)]
  · have different : (old == stored) = false := by simpa using equal
    simp only [different, Bool.not_false, if_true, Bool.false_eq_true, if_false]
    rw [run_bind_ok (countWrite_run s)]

/-- A counted write of an array that no link names is a plain write. -/
theorem writeCounted_unlinked_run (s : State) {root : Nat} {previous stored : List Value}
    (lookup : s.heap[root]? = some previous)
    (unlinked : ∀ v src f, (v, src, f) ∈ s.links → v ≠ root ∧ src ≠ root) :
    (writeCounted root stored).run s = .ok (.ref root,
      {s with heap := s.heap.set! root stored, writes := if previous == stored then s.writes else s.writes + 1}) := by
  have lt : root < s.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  rw [writeCounted_run s lookup]
  exact writeLinked_unlinked {s with writes := if previous == stored then s.writes else s.writes + 1}
    lt stored unlinked

/-- A counted write that does not shorten its array, on a state with valid
links: it succeeds, the written array holds the stored list, only the
written array's link component changes, the links stay valid, and the
component's elements come from the stored list or the component's old
arrays. -/
theorem writeCounted_linked {s : State} (valid : LinksValid s) {root : Nat} {old stored : List Value}
    (lookup : s.heap[root]? = some old) (longer : old.length ≤ stored.length) :
    ∃ h, (writeCounted root stored).run s =
        .ok (.ref root, {s with heap := h, writes := if old == stored then s.writes else s.writes + 1}) ∧
      h.size = s.heap.size ∧ h[root]? = some stored ∧
      (∀ a, ¬ LinkConnected s.links root a → h[a]? = s.heap[a]?) ∧
      LinksValid {s with heap := h} ∧
      ComponentFrom s.links root stored s {s with heap := h} := by
  have lt : root < s.heap.size := (Array.getElem?_eq_some_iff.mp lookup).1
  let s' : State := {s with writes := if old == stored then s.writes else s.writes + 1}
  have valid' : LinksValid s' := LinkClauses.linksValid_of_same valid rfl rfl
  obtain ⟨h, run, hSize⟩ := writeLinked_success valid' (c := root) lt stored
  have root' := writeLinked_root valid' run
  have frame := writeLinked_preserves run
  have links' := linksValid_after_writeLinked valid' (fun o found => by
    have same : s'.heap[root]? = some old := lookup
    rw [same] at found
    cases Option.some.inj found
    exact longer) run
  have contents := writeLinked_contents run
  refine ⟨h, by rw [writeCounted_run s lookup]; exact run, hSize, root', ?_, ?_, ?_⟩
  · intro a outside
    exact frame.heap a outside
  · exact LinkClauses.linksValid_of_same links' rfl rfl
  · intro a ys y found member connected
    exact contents a ys y found member connected

end Ownership.LinkedWriteRun
