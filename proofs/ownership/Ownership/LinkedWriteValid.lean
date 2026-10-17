-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.StatementChecks.LinkedWriteInstance

/-! `LinksValid` survives a successful `writeLinked` that does not shorten the
written array (#169, the contents clause).

`writeLinked c xs` writes `c`, then `spliceUp` rewrites each source above `c`
to its old first or last element beside the view's new contents, and
`refreshDown` rewrites every view below the chain's top from its source's
final contents. The proofs here take the run's success as a hypothesis (the
step case has the run), so they never need the fuel to suffice.

`Below links root x` is the subtree order: `x` is `root` or a view of an
array below `root`. With `bounded` and `unique` the links form a forest, so
a node has one parent (`source_unique`, `below_parent`), a strict descendant
lies below one child (`below_child`), and two children's subtrees are
disjoint (`below_disjoint`). The splice changes arrays below its top only and
does not shorten the top (`spliceUp_valid`); the refresh makes every link
whose source is below the top consistent and changes strict descendants only
(`refreshDown_valid`); a link outside the top's subtree has both ends
untouched. Lengths below the top are non-decreasing by induction on `Below`,
so every source stays nonempty (`linksValid_after_writeLinked`). -/

namespace Ownership.LinkedWriteValid

open InPlaceSemantics Soundness LinkedWriteFrame

/-- `x` is `root`, or a view of an array below `root`. -/
inductive Below (links : Links) (root : Nat) : Nat → Prop
  | refl : Below links root root
  | step {s v : Nat} {front : Bool} : Below links root s → (v, s, front) ∈ links →
      Below links root v

/-- The link structure without the heap: a view is above its source and
    below the heap's size, and no view has two sources. -/
structure Shape (links : Links) (size : Nat) : Prop where
  bounded : ∀ v s front, (v, s, front) ∈ links → s < v ∧ v < size
  unique : (links.map (·.1)).Nodup

theorem Shape.of_valid {hs : State} (valid : LinksValid hs) : Shape hs.links hs.heap.size :=
  ⟨valid.bounded, valid.unique⟩

theorem below_ge {links : Links} {size root x : Nat} (shape : Shape links size)
    (below : Below links root x) : root ≤ x := by
  induction below with
  | refl => exact Nat.le_refl _
  | step _ member ih => exact Nat.le_trans ih (Nat.le_of_lt (shape.bounded _ _ _ member).1)

theorem below_trans {links : Links} {root x y : Nat} (first : Below links root x)
    (second : Below links x y) : Below links root y := by
  induction second with
  | refl => exact first
  | step _ member ih => exact .step ih member

/-- A view has one source. -/
theorem source_unique {links : Links} {v s s' : Nat} {f f' : Bool}
    (unique : (links.map (·.1)).Nodup) (first : (v, s, f) ∈ links)
    (second : (v, s', f') ∈ links) : s = s' ∧ f = f' := by
  induction links with
  | nil => simp at first
  | cons link rest ih =>
    simp only [List.map_cons, List.nodup_cons] at unique
    obtain ⟨fresh, restUnique⟩ := unique
    simp only [List.mem_cons] at first second
    rcases first with rfl | first <;> rcases second with second | second
    · cases second
      exact ⟨rfl, rfl⟩
    · exact absurd (List.mem_map.mpr ⟨(v, s', f'), second, rfl⟩) fresh
    · subst second
      exact absurd (List.mem_map.mpr ⟨(v, s, f), first, rfl⟩) fresh
    · exact ih restUnique first second

/-- Below the root, a node other than the root has its one parent below. -/
theorem below_parent {links : Links} {size root v s : Nat} {f : Bool} (shape : Shape links size)
    (below : Below links root v) (ne : v ≠ root) (member : (v, s, f) ∈ links) :
    Below links root s := by
  cases below with
  | refl => exact absurd rfl ne
  | step belowS member' =>
    obtain ⟨rfl, rfl⟩ := source_unique shape.unique member member'
    exact belowS

/-- A strict descendant lies below one child of the root. -/
theorem below_child {links : Links} {root y : Nat} (below : Below links root y) (ne : y ≠ root) :
    ∃ v f, (v, root, f) ∈ links ∧ Below links v y := by
  induction below with
  | refl => exact absurd rfl ne
  | @step s v f belowS member ih =>
    by_cases same : s = root
    · subst same
      exact ⟨v, f, member, .refl⟩
    · obtain ⟨v', f', member', below'⟩ := ih same
      exact ⟨v', f', member', .step below' member⟩

/-- Two children's subtrees are disjoint. -/
theorem below_disjoint {links : Links} {size c v₁ v₂ y : Nat} {f₁ f₂ : Bool}
    (shape : Shape links size) (first : (v₁, c, f₁) ∈ links) (second : (v₂, c, f₂) ∈ links)
    (ne : v₁ ≠ v₂) (below₁ : Below links v₁ y) (below₂ : Below links v₂ y) : False := by
  induction below₂ with
  | refl =>
    have parent : Below links v₁ c := below_parent shape below₁ (Ne.symm ne) second
    have ge := below_ge shape parent
    have lt := (shape.bounded _ _ _ first).1
    omega
  | @step s v f belowS member ih =>
    by_cases same : v = v₁
    · subst same
      obtain ⟨rfl, _⟩ := source_unique shape.unique first member
      have ge := below_ge shape belowS
      have lt := (shape.bounded _ _ _ second).1
      omega
    · exact ih (below_parent shape below₁ same member)

theorem viewOf_length (front : Bool) (xs : List Value) : (viewOf front xs).length = xs.length - 1 := by
  unfold viewOf
  split
  · simp
  · simp

/-- What a `set!` put at its own address. -/
theorem set_self_eq {heap : Array (List Value)} {c : Nat} {xs now : List Value} (lt : c < heap.size)
    (lookup : (heap.set! c xs)[c]? = some now) : xs = now := by
  simp [Array.getElem?_setIfInBounds_self_of_lt lt] at lookup
  exact lookup

/-! ## The splice -/

/-- After `spliceUp depth x` from a state that agrees with `orig` outside the
    subtree of `x` and does not shorten `x`: the top `r` has `x` below it, the
    state agrees with `orig` outside the subtree of `r`, `r` is not shortened,
    and `r` is no view. -/
theorem spliceUp_valid {orig : State} (valid : LinksValid orig) (depth : Nat) :
    ∀ {x : Nat} {cur post : State} {r : Nat},
      cur.links = orig.links → cur.heap.size = orig.heap.size →
      (∀ y, ¬ Below orig.links x y → cur.heap[y]? = orig.heap[y]?) →
      (∀ old now, orig.heap[x]? = some old → cur.heap[x]? = some now → old.length ≤ now.length) →
      (spliceUp depth x).run cur = .ok (r, post) →
      post.links = orig.links ∧ post.heap.size = orig.heap.size ∧
      Below orig.links r x ∧
      (∀ y, ¬ Below orig.links r y → post.heap[y]? = orig.heap[y]?) ∧
      (∀ old now, orig.heap[r]? = some old → post.heap[r]? = some now → old.length ≤ now.length) ∧
      (∀ s f, (r, s, f) ∉ orig.links) := by
  induction depth with
  | zero =>
    intro x cur post r _ _ _ _ run
    change Except.error "view chain exhausted fuel" = Except.ok (r, post) at run
    contradiction
  | succ depth ih =>
    intro x cur post r same size outside longer run
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
      refine ⟨same, size, .refl, outside, longer, ?_⟩
      intro s f member
      have := List.find?_eq_none.mp found (x, s, f) member
      simp at this
    | some edge =>
      rcases edge with ⟨view, source, front⟩
      have view_eq : view = x := by
        have test := List.find?_some found
        simpa using test
      subst view_eq
      have member : (view, source, front) ∈ orig.links := List.mem_of_find?_eq_some found
      have shape := Shape.of_valid valid
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
        -- The parent is not below the view, so its contents are the original.
        have sourceOutside : ¬ Below orig.links view source := by
          intro below
          have := below_ge shape below
          omega
        have baseOrig : orig.heap[source]? = some base := by
          rw [← outside source sourceOutside]
          exact baseLookup
        obtain ⟨origSource, origSourceLookup, origNonempty⟩ := valid.sources _ _ _ member
        obtain ⟨origSource', origSourceLookup', origViewLookup⟩ := valid.contents _ _ _ member
        have baseEq : base = origSource := by
          rw [origSourceLookup] at baseOrig
          exact (Option.some.inj baseOrig).symm
        have baseNonempty : base ≠ [] := baseEq ▸ origNonempty
        have viewOrig : orig.heap[view]? = some (viewOf front base) := by
          rw [origSourceLookup'] at baseOrig
          rw [← Option.some.inj baseOrig]
          exact origViewLookup
        have viewBelow : Below orig.links source view := .step .refl member
        -- The written source is one longer than the view's new contents.
        have newLength : (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1)).length
            = xs.length + 1 := by
          have pos : 0 < base.length := List.length_pos_iff.mpr baseNonempty
          split <;> simp <;> omega
        have viewLonger := longer _ _ viewOrig xsLookup
        rw [viewOf_length] at viewLonger
        obtain ⟨links', size', belowR, outsideR, longerR, noView⟩ := ih (x := source) (cur := {cur with heap := cur.heap.set! source (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))}) same
          (by simpa using size)
          (by
            intro y notBelow
            have neSource : y ≠ source := fun eq => notBelow (eq ▸ .refl)
            have notBelowView : ¬ Below orig.links view y := fun below =>
              notBelow (below_trans viewBelow below)
            rw [HeapProof.lookup_set_other cur.heap source _ neSource]
            exact outside y notBelowView)
          (by
            intro old now oldLookup nowLookup
            rw [origSourceLookup] at oldLookup
            have oldEq := Option.some.inj oldLookup
            have lt : source < cur.heap.size := by omega
            have nowEq := set_self_eq lt nowLookup
            rw [← nowEq, newLength, ← oldEq, ← baseEq]
            omega)
          rest
        exact ⟨links', size', .step belowR member, outsideR, longerR, noView⟩

/-! ## The refresh -/

/-- The descendant loop over a list of links whose sources are compared with
    `c`: it changes only the subtrees of the children it meets, makes each
    such child a view of `c`'s contents, and makes every link below such a
    child consistent. `ih` is the refresh lemma at the smaller depth. -/
theorem refreshLoop_valid {links : Links} {size : Nat} (shape : Shape links size) (depth : Nat)
    (ih : ∀ {c : Nat} {cur post : State} {u : Unit}, cur.links = links → cur.heap.size = size →
      (refreshDown depth c).run cur = .ok (u, post) →
      post.links = links ∧ post.heap.size = cur.heap.size ∧
      (∀ v s f, (v, s, f) ∈ links → Below links c s →
        ∃ src, post.heap[s]? = some src ∧ post.heap[v]? = some (viewOf f src)) ∧
      (∀ y, (Below links c y → y = c) → post.heap[y]? = cur.heap[y]?))
    (c : Nat) :
    ∀ (items : Links) {cur post : State} {u : Unit},
      cur.links = links → cur.heap.size = size →
      (∀ e ∈ items, e ∈ links) → (items.map (·.1)).Nodup →
      (forIn items () (refreshStep depth c)).run cur = .ok (u, post) →
      post.links = links ∧ post.heap.size = cur.heap.size ∧
      (∀ y, (∀ v s f, (v, s, f) ∈ items → s = c → ¬ Below links v y) →
        post.heap[y]? = cur.heap[y]?) ∧
      (∀ v s f, (v, s, f) ∈ items → s = c →
        (∃ src, post.heap[c]? = some src ∧ post.heap[v]? = some (viewOf f src)) ∧
        ∀ v' s' f', (v', s', f') ∈ links → Below links v s' →
          ∃ src, post.heap[s']? = some src ∧ post.heap[v']? = some (viewOf f' src)) := by
  intro items
  induction items with
  | nil =>
    intro cur post u same _ _ _ run
    simp only [List.forIn_nil] at run
    change Except.ok ((), cur) = Except.ok (u, post) at run
    cases run
    refine ⟨same, rfl, fun _ _ => rfl, ?_⟩
    intro v s f member
    simp at member
  | cons head rest ihRest =>
    rcases head with ⟨v, s, f⟩
    intro cur post u same sizeEq sub nodup run
    simp only [List.map_cons, List.nodup_cons] at nodup
    obtain ⟨fresh, restNodup⟩ := nodup
    have memberLinks : (v, s, f) ∈ links := sub _ (by simp)
    have subRest : ∀ e ∈ rest, e ∈ links := fun e h => sub e (by simp [h])
    rw [List.forIn_cons] at run
    obtain ⟨stepResult, middle, stepRun, restRun⟩ := bind_success run
    by_cases sameC : s = c
    · rw [sameC] at memberLinks
      have vLt : v < size := (shape.bounded _ _ _ memberLinks).2
      have cLt : c < v := (shape.bounded _ _ _ memberLinks).1
      simp only [refreshStep, sameC, beq_self_eq_true, if_true] at stepRun
      obtain ⟨xs, afterXs, readXs, rest₁⟩ := bind_success stepRun
      obtain ⟨eqXs, xsLookup⟩ := array_success readXs
      subst afterXs
      obtain ⟨w, mid₁, writeRun, rest₂⟩ := bind_success rest₁
      rw [write_run] at writeRun
      split at writeRun
      · contradiction
      · cases writeRun
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
        obtain ⟨links₂, size₂, cons₂, unch₂⟩ := ih (c := v) (cur := {cur with heap := cur.heap.set! v (viewOf f xs)}) same (by simpa using sizeEq) refreshRun
        obtain ⟨links₃, size₃, unch₃, cons₃⟩ := ihRest links₂ (by rw [size₂]; simpa using sizeEq)
          subRest restNodup restRun
        have cNotBelowV : ¬ Below links v c := fun below => by
          have := below_ge shape below
          omega
        -- A child of `c` in the rest is not `v`, so its subtree is disjoint from `v`'s.
        have restDisjoint : ∀ v₂ s₂ f₂, (v₂, s₂, f₂) ∈ rest → s₂ = c → ∀ y,
            Below links v y → ¬ Below links v₂ y := by
          intro v₂ s₂ f₂ member₂ eq₂ y belowV belowV₂
          rw [eq₂] at member₂
          have ne : v ≠ v₂ := by
            intro eq
            exact fresh (List.mem_map.mpr ⟨(v₂, c, f₂), member₂, by simp [eq]⟩)
          exact below_disjoint shape memberLinks (subRest _ member₂) ne belowV belowV₂
        have cSame : post.heap[c]? = some xs := by
          rw [unch₃ c (fun v₂ s₂ f₂ member₂ eq₂ below => by
            rw [eq₂] at member₂
            have := below_ge shape below
            have := (shape.bounded _ _ _ (subRest _ member₂)).1
            omega)]
          rw [unch₂ c (fun below => absurd below cNotBelowV)]
          rw [HeapProof.lookup_set_other cur.heap v _ (by omega)]
          exact xsLookup
        refine ⟨links₃, by rw [size₃, size₂]; simp, ?_, ?_⟩
        · intro y cond
          have notV : ¬ Below links v y := cond v s f (by simp) sameC
          rw [unch₃ y (fun v₂ s₂ f₂ member₂ eq₂ => cond v₂ s₂ f₂ (by simp [member₂]) eq₂)]
          rw [unch₂ y (fun below => absurd below notV)]
          exact HeapProof.lookup_set_other cur.heap v _ (fun eq => notV (eq ▸ .refl))
        · intro v₂ s₂ f₂ member₂ eq₂
          simp only [List.mem_cons] at member₂
          rcases member₂ with eq | tail
          · cases eq
            refine ⟨⟨xs, cSame, ?_⟩, ?_⟩
            · rw [unch₃ v (fun v₂ s₂ f₂ member₂ eq₂ => restDisjoint v₂ s₂ f₂ member₂ eq₂ v .refl)]
              rw [unch₂ v (fun _ => rfl)]
              have lt : v < cur.heap.size := by omega
              simp [Array.getElem?_setIfInBounds_self_of_lt lt]
            · intro v' s' f' member' belowS'
              obtain ⟨src, srcLookup, viewLookup⟩ := cons₂ v' s' f' member' belowS'
              refine ⟨src, ?_, ?_⟩
              · rw [unch₃ s' (fun v₂ s₂ f₂ member₂ eq₂ => restDisjoint v₂ s₂ f₂ member₂ eq₂ s' belowS')]
                exact srcLookup
              · rw [unch₃ v' (fun v₂ s₂ f₂ member₂ eq₂ =>
                  restDisjoint v₂ s₂ f₂ member₂ eq₂ v' (.step belowS' member'))]
                exact viewLookup
          · exact cons₃ v₂ s₂ f₂ tail eq₂
    · have ne : (s == c) = false := by simp [sameC]
      simp only [refreshStep, ne, Bool.false_eq_true, if_false] at stepRun
      change Except.ok (ForInStep.yield (), cur) = Except.ok (stepResult, middle) at stepRun
      cases stepRun
      change (forIn rest () (refreshStep depth c)).run cur = .ok (u, post) at restRun
      obtain ⟨links₃, size₃, unch₃, cons₃⟩ := ihRest same sizeEq subRest restNodup restRun
      refine ⟨links₃, size₃, ?_, ?_⟩
      · intro y cond
        exact unch₃ y (fun v₂ s₂ f₂ member₂ eq₂ => cond v₂ s₂ f₂ (by simp [member₂]) eq₂)
      · intro v₂ s₂ f₂ member₂ eq₂
        simp only [List.mem_cons] at member₂
        rcases member₂ with eq | tail
        · cases eq
          exact absurd eq₂ sameC
        · exact cons₃ v₂ s₂ f₂ tail eq₂

/-- After `refreshDown depth c`: every link whose source is below `c` is
    consistent, and only strict descendants of `c` changed. -/
theorem refreshDown_valid {links : Links} {size : Nat} (shape : Shape links size) (depth : Nat) :
    ∀ {c : Nat} {cur post : State} {u : Unit}, cur.links = links → cur.heap.size = size →
      (refreshDown depth c).run cur = .ok (u, post) →
      post.links = links ∧ post.heap.size = cur.heap.size ∧
      (∀ v s f, (v, s, f) ∈ links → Below links c s →
        ∃ src, post.heap[s]? = some src ∧ post.heap[v]? = some (viewOf f src)) ∧
      (∀ y, (Below links c y → y = c) → post.heap[y]? = cur.heap[y]?) := by
  induction depth with
  | zero =>
    intro c cur post u _ _ run
    change Except.error "view chain exhausted fuel" = Except.ok (u, post) at run
    contradiction
  | succ depth ih =>
    intro c cur post u same sizeEq run
    change ((forIn cur.links () (refreshStep depth c) >>= fun _ => pure ()) :
      M Unit).run cur = .ok (u, post) at run
    rw [same] at run
    obtain ⟨u', middle, loopRun, finish⟩ := bind_success run
    change Except.ok ((), middle) = Except.ok (u, post) at finish
    cases finish
    obtain ⟨links', size', unch, cons⟩ :=
      refreshLoop_valid shape depth (fun same sizeEq run => ih same sizeEq run) c links same sizeEq
        (fun _ h => h) shape.unique loopRun
    refine ⟨links', size', ?_, ?_⟩
    · intro v s f member belowS
      by_cases eq : s = c
      · subst eq
        exact (cons v s f member rfl).1
      · obtain ⟨v₁, f₁, member₁, below₁⟩ := below_child belowS eq
        exact (cons v₁ c f₁ member₁ rfl).2 v s f member below₁
    · intro y cond
      apply unch y
      intro v s f member eq below
      rw [eq] at member
      have belowC : Below links c y := below_trans (.step .refl member) below
      have := cond belowC
      subst this
      have := below_ge shape below
      have := (shape.bounded _ _ _ member).1
      omega

/-! ## The linked write -/

/-- `LinksValid` after a successful `writeLinked c xs` that does not shorten
    `c`. The write, the splice and the refresh keep the links and the heap's
    size; a link below the splice's top is consistent by the refresh, a link
    outside it has both ends untouched; and no array below the top gets
    shorter, so every source stays nonempty. -/
theorem linksValid_after_writeLinked {hs hs' : State} (valid : LinksValid hs) {c : Nat}
    {xs : List Value} (nonshort : ∀ old, hs.heap[c]? = some old → old.length ≤ xs.length)
    {r : Value} (run : (writeLinked c xs).run hs = .ok (r, hs')) : LinksValid hs' := by
  change ((write c xs) >>= fun r => do
    let s ← get
    if s.links.isEmpty then return r
    let ancestor ← spliceUp (s.heap.size + 1) c
    refreshDown (s.heap.size + 1) ancestor
    pure r).run hs = .ok (r, hs') at run
  obtain ⟨written, afterWrite, writeRun, rest⟩ := bind_success run
  rw [write_run] at writeRun
  split at writeRun
  · contradiction
  · rename_i inRange
    have cLt : c < hs.heap.size := by omega
    have afterLinks : afterWrite.links = hs.links := by
      cases writeRun
      rfl
    have afterHeap : afterWrite.heap = hs.heap.set! c xs := by
      cases writeRun
      rfl
    change ((if afterWrite.links.isEmpty then pure written else do
      let ancestor ← spliceUp (afterWrite.heap.size + 1) c
      refreshDown (afterWrite.heap.size + 1) ancestor
      pure written) : M Value).run afterWrite = .ok (r, hs') at rest
    split at rest
    · rename_i empty
      change Except.ok (written, afterWrite) = Except.ok (r, hs') at rest
      cases rest
      exact Soundness.linksValid_of_empty _ (List.isEmpty_iff.mp empty)
    · obtain ⟨anc, afterSplice, spliceRun, restSplice⟩ := bind_success rest
      obtain ⟨sl, ss, _, outsideR, longerR, noView⟩ :=
        spliceUp_valid valid _ (x := c) (cur := afterWrite) afterLinks (by rw [afterHeap]; simp)
          (by
            intro y notBelow
            have ne : y ≠ c := fun eq => notBelow (eq ▸ .refl)
            rw [afterHeap, HeapProof.lookup_set_other _ _ _ ne])
          (by
            intro old now oldLookup nowLookup
            rw [afterHeap] at nowLookup
            rw [← set_self_eq cLt nowLookup]
            exact nonshort old oldLookup)
          spliceRun
      obtain ⟨finished, afterRefresh, refreshRun, finishRun⟩ := bind_success restSplice
      change Except.ok (written, afterRefresh) = Except.ok (r, hs') at finishRun
      have finishEq : afterRefresh = hs' := by
        cases finishRun
        rfl
      rw [← finishEq]
      have shape := Shape.of_valid valid
      obtain ⟨rl, rs, cons, unch⟩ := refreshDown_valid shape _ (c := anc) sl ss refreshRun
      -- No array below the top gets shorter.
      have lengths : ∀ y, Below hs.links anc y → ∀ old now, hs.heap[y]? = some old →
          afterRefresh.heap[y]? = some now → old.length ≤ now.length := by
        intro y below
        induction below with
        | refl =>
          intro old now oldLookup nowLookup
          rw [unch anc (fun _ => rfl)] at nowLookup
          exact longerR old now oldLookup nowLookup
        | @step s v f belowS member ihLength =>
          intro old now oldLookup nowLookup
          obtain ⟨oldSource, oldSourceLookup, oldViewLookup⟩ := valid.contents v s f member
          obtain ⟨newSource, newSourceLookup, newViewLookup⟩ := cons v s f member belowS
          rw [oldViewLookup] at oldLookup
          rw [newViewLookup] at nowLookup
          rw [← Option.some.inj oldLookup, ← Option.some.inj nowLookup, viewOf_length, viewOf_length]
          have := ihLength oldSource newSource oldSourceLookup newSourceLookup
          omega
      refine ⟨?_, ?_, ?_, ?_⟩
      · rw [rl, rs, ss]
        exact valid.bounded
      · intro v s f member
        rw [rl] at member
        obtain ⟨oldSource, oldSourceLookup, oldNonempty⟩ := valid.sources v s f member
        by_cases below : Below hs.links anc s
        · obtain ⟨newSource, newSourceLookup, _⟩ := cons v s f member below
          refine ⟨newSource, newSourceLookup, ?_⟩
          have longer := lengths s below oldSource newSource oldSourceLookup newSourceLookup
          have pos : 0 < oldSource.length := List.length_pos_iff.mpr oldNonempty
          intro empty
          rw [empty, List.length_nil] at longer
          omega
        · refine ⟨oldSource, ?_, oldNonempty⟩
          rw [unch s (fun b => absurd b below), outsideR s below]
          exact oldSourceLookup
      · rw [rl]
        exact valid.unique
      · intro v s f member
        rw [rl] at member
        by_cases below : Below hs.links anc s
        · exact cons v s f member below
        · have viewOutside : ¬ Below hs.links anc v := fun belowV =>
            below (below_parent shape belowV (fun eq => noView s f (eq ▸ member)) member)
          obtain ⟨oldSource, oldSourceLookup, oldViewLookup⟩ := valid.contents v s f member
          refine ⟨oldSource, ?_, ?_⟩
          · rw [unch s (fun b => absurd b below), outsideR s below]
            exact oldSourceLookup
          · rw [unch v (fun b => absurd b viewOutside), outsideR v viewOutside]
            exact oldViewLookup

end Ownership.LinkedWriteValid
