import Ownership.Semantics

namespace Ownership.HeapProof

open InPlaceSemantics
abbrev Heap := Array (List Value)

private theorem list_equal_of_tests {xs ys : List α}
    (test : {x // x ∈ xs} → α → Bool)
    (sound : ∀ x y, test x y = true → x.val = y)
    (length : xs.length = ys.length)
    (tests : (xs.attach.zip ys).all (fun (x, y) => test x y) = true) : xs = ys := by
  apply List.ext_getElem length
  intro i hi hj
  have hk : i < (xs.attach.zip ys).length := by simp; omega
  have h := List.all_eq_true.mp tests _ (List.getElem_mem hk)
  simp only [List.get_eq_getElem, List.getElem_zip] at h
  simpa using sound _ _ h

/-- The privileged map close comparison is ordinary structural equality of
    immediate heap values (references compare addresses), with no assumption
    about the contents behind those references. -/
theorem value_equal_sound (a b : Value) (h : a.equal b = true) : a = b := by
  cases a <;> cases b <;> simp only [Value.equal, Bool.and_eq_true, beq_iff_eq,
    Bool.false_eq_true] at h
  all_goals try first | contradiction | (subst_vars; rfl)
  case record.record xs ys =>
    exact congrArg Value.record (list_equal_of_tests _
      (fun x y h => value_equal_sound x.val y h) h.1 h.2)
  case closure.closure i xs j ys =>
    obtain ⟨⟨rfl, length⟩, tests⟩ := h
    exact congrArg (Value.closure i) (list_equal_of_tests _
      (fun x y h => value_equal_sound x.val y h) length tests)
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals have bound := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

theorem values_beq_sound (xs ys : List Value) (h : (xs == ys) = true) : xs = ys := by
  cases xs with
  | nil => cases ys <;> simp_all
  | cons x xs =>
    cases ys with
    | nil => simp_all
    | cons y ys =>
      change (x.equal y && (xs == ys)) = true at h
      simp only [Bool.and_eq_true] at h
      obtain ⟨head, tail⟩ := h
      rw [value_equal_sound x y head, values_beq_sound xs ys tail]

/- A concrete, finite heap expansion. The footprint retains multiplicity:
    two paths to the same cell occur twice, including inside captures. The
    depth index is exactly the fuel consumed by executable `snapshot`. -/
mutual
inductive Represents (heap : Heap) : Nat → Value → Observation → List Nat → Prop where
  | int : Represents heap (n + 1) (.int i) (.int i) []
  | record : RepresentsMany heap n vs os cs →
      Represents heap (n + 1) (.record vs) (.record os) cs
  | closure : RepresentsMany heap n vs os cs →
      Represents heap (n + 1) (.closure decl vs) (.closure decl os) cs
  | ref : heap[c]? = some vs → RepresentsMany heap n vs os cs →
      Represents heap (n + 1) (.ref c) (.list os) (c :: cs)
inductive RepresentsMany (heap : Heap) : Nat → List Value → List Observation → List Nat → Prop where
  | nil : RepresentsMany heap n [] [] []
  | cons : Represents heap n v o cs → RepresentsMany heap n vs os ds →
      RepresentsMany heap n (v :: vs) (o :: os) (cs ++ ds)
end

@[simp] theorem except_ok_bind (a : α) (f : α → Except String β) :
    (Except.ok a >>= f) = f a := rfl
@[simp] theorem except_ok_map (a : α) (f : α → β) :
    (f <$> Except.ok a : Except String β) = .ok (f a) := rfl

mutual
theorem snapshot_of_represents (h : Represents heap n v o cs) :
    snapshot heap n v = .ok o := by
  cases h with
  | int => rfl
  | record hs => simp [snapshot, snapshots_of_represents hs]
  | closure hs => simp [snapshot, snapshots_of_represents hs]
  | ref lookup hs => simp [snapshot, lookup, Option.toExcept, snapshots_of_represents hs]
theorem snapshots_of_represents (h : RepresentsMany heap n vs os cs) :
    vs.mapM (snapshot heap n) = .ok os := by
  cases h with
  | nil => rfl
  | cons hv hs => simp [snapshot_of_represents hv, snapshots_of_represents hs]
end

/- Changing cells outside a value's concrete footprint cannot change its
    observation. No global heap equality or alias-free-heap assumption. -/
mutual
theorem represents_frame (h : Represents heap n v o cs)
    (same : ∀ c ∈ cs, heap'[c]? = heap[c]?) :
    Represents heap' n v o cs := by
  cases h with
  | int => exact .int
  | record hs => exact .record (representsMany_frame hs same)
  | closure hs => exact .closure (representsMany_frame hs same)
  | ref lookup hs =>
    apply Represents.ref (by rw [same _ (by simp), lookup])
    exact representsMany_frame hs (fun c hc => same c (by simp [hc]))
theorem representsMany_frame (h : RepresentsMany heap n vs os cs)
    (same : ∀ c ∈ cs, heap'[c]? = heap[c]?) :
    RepresentsMany heap' n vs os cs := by
  cases h with
  | nil => exact .nil
  | cons hv hs =>
    exact .cons (represents_frame hv (fun c hc => same c (by simp [hc])))
      (representsMany_frame hs (fun c hc => same c (by simp [hc])))
end

theorem representsMany_append (a : RepresentsMany heap n as aos acs)
    (b : RepresentsMany heap n bs bos bcs) :
    RepresentsMany heap n (as ++ bs) (aos ++ bos) (acs ++ bcs) := by
  induction as generalizing aos acs with
  | nil => cases a; simpa using b
  | cons v vs ih =>
    cases a with
    | cons hv hs => simpa [List.append_assoc] using RepresentsMany.cons hv (ih hs)

theorem lookup_set_other (heap : Heap) (root : Nat) (xs : List Value)
    (different : c ≠ root) : (heap.set! root xs)[c]? = heap[c]? := by
  simp [Ne.symm different]

theorem represents_after_write (h : Represents heap n v o cs) (fresh : root ∉ cs) :
    Represents (heap.set! root xs) n v o cs :=
  represents_frame h fun _ hc => lookup_set_other heap root xs (fun eq => fresh (eq ▸ hc))

theorem representsMany_after_write (h : RepresentsMany heap n vs os cs) (fresh : root ∉ cs) :
    RepresentsMany (heap.set! root xs) n vs os cs :=
  representsMany_frame h fun _ hc => lookup_set_other heap root xs (fun eq => fresh (eq ▸ hc))

mutual
theorem represents_bound (h : Represents heap n v o cs) :
    ∀ c ∈ cs, c < heap.size := by
  cases h with
  | int => simp
  | record hs => exact representsMany_bound hs
  | closure hs => exact representsMany_bound hs
  | ref lookup hs =>
    intro c hc
    cases List.mem_cons.mp hc with
    | inl eq => subst c; exact (Array.getElem?_eq_some_iff.mp lookup).1
    | inr mem => exact representsMany_bound hs c mem
theorem representsMany_bound (h : RepresentsMany heap n vs os cs) :
    ∀ c ∈ cs, c < heap.size := by
  cases h with
  | nil => simp
  | cons hv hs =>
    intro c hc
    cases List.mem_append.mp hc with
    | inl mem => exact represents_bound hv c mem
    | inr mem => exact representsMany_bound hs c mem
end

theorem representsMany_after_alloc (h : RepresentsMany heap n vs os cs) :
    RepresentsMany (heap.push xs) n vs os cs :=
  representsMany_frame h fun c hc => by
    have bound := representsMany_bound h c hc
    have different : c ≠ heap.size := by omega
    simp [Array.getElem?_push, bound, different]

end Ownership.HeapProof
