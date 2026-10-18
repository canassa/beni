import Ownership.Tree.Path

/-! # The marker's meaning, and what is proved about it

`Den p c`: the abstract path `p` stands for the concrete path `c`. A concrete
step stands for itself, and the marker `⟨Tree⟩` for any run of subtree steps,
the empty run included ("every value of type `T` at or below the position",
§16.7's amendment, *What `⟨T⟩` stands for*).

Proved here, with no `sorry`:

* `semF_complete`: an exact search over two abstract paths finds every pair
  of concrete paths they stand for of which one is a prefix of the other (a
  holder and what it holds).
* `conflict_complete`: on canonical paths, the spec's overlap and holding
  (`Config.conflict`, both rules as the amendment states them) are true
  wherever such a pair exists. So a write is never taken to be apart from a
  holder that holds it.
* `extend_sound`: the fold with the marker keeps every concrete path:
  extending a tree position by a constructor step stands for the extended
  concrete path.
* `master_fold_unsound`: `master`'s fold does not; `#Node.0#Node.1` (the left
  subtree's list) is not among the paths of `#Node.1`.
* `root_apart` and `sides_apart`: the root's list and every list of the left
  subtree are two places, and so are the left and right subtrees' lists. -/

namespace Ownership.Tree

inductive Den : List Step → List Step → Prop
  | nil : Den [] []
  | step {p c} (s : Step) : s ≠ .mark → Den p c → Den (s :: p) (s :: c)
  | skip {p c} : Den p c → Den (.mark :: p) c
  | more {p c} (t : Step) : isT t = true → Den (.mark :: p) c → Den (.mark :: p) (t :: c)

/-- `c` is a prefix of `d`. -/
inductive Pre : List Step → List Step → Prop
  | nil {d} : Pre [] d
  | cons {c d} (a : Step) : Pre c d → Pre (a :: c) (a :: d)

/-- An exact search; out of fuel it answers `true`, conservatively. -/
def semF : Nat → List Step → List Step → Bool
  | 0, _, _ => true
  | _ + 1, [], _ => true
  | _ + 1, _ :: _, [] => true
  | f + 1, a :: p, b :: q =>
    if a == .mark then
      if b == .mark then semF f p (.mark :: q) || semF f (.mark :: p) q
      else semF f p (b :: q) || (isT b && semF f (.mark :: p) q)
    else if b == .mark then semF f (a :: p) q || (isT a && semF f p (.mark :: q))
    else a == b && semF f p q

theorem Den.nil_left {c : List Step} : Den [] c → c = [] := by
  intro h; cases h; rfl

theorem Pre.cons_inv {a b : Step} {c d : List Step} : Pre (a :: c) (b :: d) → a = b ∧ Pre c d := by
  intro h; cases h with
  | cons _ h => exact ⟨rfl, h⟩

theorem Pre.nil_right {c : List Step} : Pre c [] → c = [] := by
  intro h; cases h; rfl

/-- The core of the completeness argument, by induction on the total length
    of the four paths. -/
theorem semF_complete_aux : ∀ n (f : Nat) (p q c d : List Step),
    c.length + d.length + p.length + q.length ≤ n →
    Den p c → Den q d → (Pre c d ∨ Pre d c) → semF f p q = true := by
  intro n
  induction n with
  | zero =>
    intro f p q c d hn hp hq _
    have : p = [] := List.eq_nil_of_length_eq_zero (by omega)
    subst this
    cases f <;> simp [semF]
  | succ n ih =>
    intro f p q c d hn hp hq hpre
    have flip : ∀ {a b : Step} {c' d' : List Step}, (Pre (a :: c') (b :: d') ∨ Pre (b :: d') (a :: c')) →
        a = b ∧ (Pre c' d' ∨ Pre d' c') := by
      intro a b c' d' h
      rcases h with h | h
      · exact ⟨(Pre.cons_inv h).1, Or.inl (Pre.cons_inv h).2⟩
      · exact ⟨(Pre.cons_inv h).1.symm, Or.inr (Pre.cons_inv h).2⟩
    cases f with
    | zero => simp [semF]
    | succ f =>
    cases hp with
    | nil => simp [semF]
    | @step p c' a ha hp' =>
      have ha' : (a == Step.mark) = false := by cases a <;> simp_all
      cases hq with
      | nil => simp [semF]
      | @step q d' b hb hq' =>
        have hb' : (b == Step.mark) = false := by cases b <;> simp_all
        simp only [semF, ha', hb', Bool.false_eq_true, if_false, Bool.and_eq_true, beq_iff_eq]
        obtain ⟨e, h'⟩ := flip hpre
        exact ⟨e, ih f p q c' d' (by simp at hn ⊢; omega) hp' hq' h'⟩
      | @skip q d hq' =>
        simp only [semF, ha', Bool.false_eq_true, if_false, beq_self_eq_true, if_true,
          Bool.or_eq_true, Bool.and_eq_true]
        left; exact ih f (a :: p) q (a :: c') d (by simp at hn ⊢; omega) (.step a ha hp') hq' hpre
      | @more q d' t ht hq' =>
        simp only [semF, ha', Bool.false_eq_true, if_false, beq_self_eq_true, if_true,
          Bool.or_eq_true, Bool.and_eq_true]
        right
        obtain ⟨e, h'⟩ := flip hpre
        subst e
        exact ⟨ht, ih f p (.mark :: q) c' d' (by simp at hn ⊢; omega) hp' hq' h'⟩
    | @skip p c hp' =>
      cases hq with
      | nil => simp [semF]
      | @step q d' b hb hq' =>
        have hb' : (b == Step.mark) = false := by cases b <;> simp_all
        simp only [semF, beq_self_eq_true, if_true, hb', Bool.false_eq_true, if_false,
          Bool.or_eq_true, Bool.and_eq_true]
        left; exact ih f p (b :: q) c (b :: d') (by simp at hn ⊢; omega) hp' (.step b hb hq') hpre
      | @skip q d hq' =>
        simp only [semF, beq_self_eq_true, if_true, Bool.or_eq_true]
        left; exact ih f p (.mark :: q) c d (by simp at hn ⊢; omega) hp' (.skip hq') hpre
      | @more q d' t ht hq' =>
        simp only [semF, beq_self_eq_true, if_true, Bool.or_eq_true]
        left; exact ih f p (.mark :: q) c (t :: d') (by simp at hn ⊢; omega) hp' (.more t ht hq') hpre
    | @more p c' t ht hp' =>
      cases hq with
      | nil => simp [semF]
      | @step q d' b hb hq' =>
        have hb' : (b == Step.mark) = false := by cases b <;> simp_all
        simp only [semF, beq_self_eq_true, if_true, hb', Bool.false_eq_true, if_false,
          Bool.or_eq_true, Bool.and_eq_true]
        right
        obtain ⟨e, h'⟩ := flip hpre
        subst e
        exact ⟨ht, ih f (.mark :: p) q c' d' (by simp at hn ⊢; omega) hp' hq' h'⟩
      | @skip q d hq' =>
        simp only [semF, beq_self_eq_true, if_true, Bool.or_eq_true]
        right; exact ih f (.mark :: p) q (t :: c') d (by simp at hn ⊢; omega) (.more t ht hp') hq' hpre
      | @more q d' u hu hq' =>
        -- both runs start with the same step: drop it and ask the same question
        obtain ⟨_, h'⟩ := flip hpre
        have := ih (f + 1) (.mark :: p) (.mark :: q) c' d' (by simp at hn ⊢; omega) hp' hq' h'
        simpa [semF] using this

theorem semF_complete {f : Nat} {p q c d : List Step} :
    Den p c → Den q d → (Pre c d ∨ Pre d c) → semF f p q = true :=
  semF_complete_aux _ f p q c d (Nat.le_refl _)

/-- The canonical tree segments: the root, its list, a first subtree step,
    and a region under its marker with at most one step after it. -/
def tails : List (List Step) :=
  [[], [.n1], [.n0], [.n2], [.n0, .mark], [.n2, .mark],
   [.n0, .mark, .n0], [.n0, .mark, .n1], [.n0, .mark, .n2],
   [.n2, .mark, .n0], [.n2, .mark, .n1], [.n2, .mark, .n2]]

/-- A canonical path: pair steps, then a canonical tree segment. -/
def Canon : List Step → Bool
  | [] => true
  | s :: r => if s == .p0 || s == .p1 then Canon r else tails.contains (s :: r)

/-- The finite part: every two canonical tree segments. -/
theorem tails_conflict :
    ∀ p ∈ tails, ∀ q ∈ tails, semF 7 p q = true → ({} : Config).conflict p q = true := by
  decide +kernel

theorem conflict_nil (q : List Step) : ({} : Config).conflict [] q = true := by
  simp [Config.conflict, overlap]

theorem approxHolds_pair {a : Step} (ha : a = .p0 ∨ a = .p1) (o i : List Step) :
    approxHolds false (a :: o) (a :: i) = approxHolds false o i := by
  rcases ha with h | h <;> subst h <;> rfl

theorem conflict_pair {a : Step} (ha : a = .p0 ∨ a = .p1) (p q : List Step) :
    ({} : Config).conflict (a :: p) (a :: q) = ({} : Config).conflict p q := by
  have h1 := approxHolds_pair ha p q
  have h2 := approxHolds_pair ha q p
  rcases ha with h | h <;> subst h <;> simp_all [Config.conflict, overlap]

theorem semF_pair {a : Step} (ha : a = .p0 ∨ a = .p1) {p q : List Step} :
    (∀ f, semF f (a :: p) (a :: q) = true) → ∀ f, semF f p q = true := by
  intro h f
  have := h (f + 1)
  rcases ha with e | e <;> subst e <;> simpa [semF] using this

theorem tails_head {s : Step} {r : List Step} : tails.contains (s :: r) = true → s ≠ .p0 ∧ s ≠ .p1 ∧ s ≠ .mark := by
  intro h
  simp [tails] at h
  rcases h with h | h | h | h | h | h | h | h | h | h | h <;> (obtain ⟨rfl, rfl⟩ := h; simp)

theorem tail_mem {s : Step} {r : List Step} : tails.contains (s :: r) = true → (s :: r) ∈ tails := by
  intro h; simpa using h

/-- Distinct heads where neither is a marker: the search fails at once. -/
theorem semF_heads {a b : Step} {p q : List Step} (ha : a ≠ .mark) (hb : b ≠ .mark) (hab : a ≠ b) :
    semF 1 (a :: p) (b :: q) = false := by
  have ha' : (a == Step.mark) = false := by cases a <;> simp_all
  have hb' : (b == Step.mark) = false := by cases b <;> simp_all
  have hab' : (a == b) = false := by simp [hab]
  simp [semF, ha', hb', hab']

theorem conflict_of_semF : ∀ (p q : List Step), Canon p = true → Canon q = true →
    (∀ f, semF f p q = true) → ({} : Config).conflict p q = true := by
  intro p
  induction p with
  | nil => intro q _ _ _; exact conflict_nil q
  | cons a p ih =>
    intro q hp hq hs
    have hpa : (a = .p0 ∨ a = .p1) ∨ (a :: p) ∈ tails := by
      by_cases h : a = .p0 ∨ a = .p1
      · exact Or.inl h
      · right
        have h' : (a == Step.p0 || a == Step.p1) = false := by
          rcases a <;> simp_all
        simp only [Canon, h', Bool.false_eq_true, if_false] at hp
        exact tail_mem hp
    cases q with
    | nil => simp [Config.conflict, overlap]
    | cons b q =>
      have hqb : (b = .p0 ∨ b = .p1) ∨ (b :: q) ∈ tails := by
        by_cases h : b = .p0 ∨ b = .p1
        · exact Or.inl h
        · right
          have h' : (b == Step.p0 || b == Step.p1) = false := by
            rcases b <;> simp_all
          simp only [Canon, h', Bool.false_eq_true, if_false] at hq
          exact tail_mem hq
      rcases hpa with ha | ha <;> rcases hqb with hb | hb
      · -- two pair steps
        by_cases e : a = b
        · subst e
          rw [conflict_pair ha]
          have hp' : Canon p = true := by
            rcases ha with h | h <;> subst h <;> simpa [Canon] using hp
          have hq' : Canon q = true := by
            rcases ha with h | h <;> subst h <;> simpa [Canon] using hq
          exact ih q hp' hq' (semF_pair ha hs)
        · have := semF_heads (p := p) (q := q) (by rcases ha with h | h <;> simp [h])
            (by rcases hb with h | h <;> simp [h]) e
          simp [hs 1] at this
      · -- a pair step against a tree step
        have hbt := tails_head (by simpa using hb)
        have := semF_heads (a := a) (b := b) (p := p) (q := q) (by rcases ha with h | h <;> simp [h]) hbt.2.2
          (by rcases ha with h | h <;> subst h <;> intro e <;> subst e <;> simp_all)
        simp [hs 1] at this
      · have hat := tails_head (by simpa using ha)
        have := semF_heads (a := a) (b := b) (p := p) (q := q) hat.2.2 (by rcases hb with h | h <;> simp [h])
          (by rcases hb with h | h <;> subst h <;> intro e <;> subst e <;> simp_all)
        simp [hs 1] at this
      · exact tails_conflict _ ha _ hb (hs 7)

/-- The spec's overlap and holding never miss a holder: on canonical paths,
    if a concrete path one stands for is a prefix of one the other stands
    for, they conflict. -/
theorem conflict_complete {p q c d : List Step} (hp : Canon p = true) (hq : Canon q = true)
    (hc : Den p c) (hd : Den q d) (hpre : Pre c d ∨ Pre d c) :
    ({} : Config).conflict p q = true :=
  conflict_of_semF p q hp hq fun _ => semF_complete hc hd hpre

/-! ## The fold keeps every concrete path -/

/-- A run of subtree steps. -/
def Tseq (c : List Step) : Prop := ∀ s ∈ c, isT s = true

theorem den_mark_of {σ c : List Step} {q : List Step} (hσ : Tseq σ) (h : Den q c) :
    Den (.mark :: q) (σ ++ c) := by
  induction σ with
  | nil => exact .skip h
  | cons t σ ih =>
    exact .more t (hσ t (by simp)) (ih fun s hs => hσ s (by simp [hs]))

/-- A region tail: the tree segments a subtree position takes (`[s₀]`,
    `[s₀, ⟨T⟩]`, `[s₀, ⟨T⟩, t]` with `t` a subtree step). -/
def subtreeTails : List (List Step) :=
  [[.n0], [.n2], [.n0, .mark], [.n2, .mark],
   [.n0, .mark, .n0], [.n0, .mark, .n2], [.n2, .mark, .n0], [.n2, .mark, .n2]]

/-- A tree position: pair steps, then the root or a subtree tail. -/
def TreePos : List Step → Bool
  | [] => true
  | s :: r => if s == .p0 || s == .p1 then TreePos r else subtreeTails.contains (s :: r)

theorem den_tseq {p c : List Step} (h : Den p c) : (∀ s ∈ p, s = .mark ∨ isT s = true) → Tseq c := by
  induction h with
  | nil => intro _ s hs; simp at hs
  | @step p c s hs _ ih =>
    intro hp t ht
    simp at ht
    rcases ht with rfl | ht
    · rcases hp t (by simp) with e | e
      · exact absurd e hs
      · exact e
    · exact ih (fun u hu => hp u (by simp [hu])) t ht
  | skip _ ih => intro hp; exact ih (fun u hu => hp u (by simp [hu]))
  | @more p c t ht _ ih =>
    intro hp u hu
    simp at hu
    rcases hu with rfl | hu
    · exact ht
    · exact ih hp u hu

theorem den_tail_tseq {x : Step} {r c : List Step} (hx : isT x = true)
    (hr : r = [] ∨ r = [.mark] ∨ r = [.mark, .n0] ∨ r = [.mark, .n2]) (h : Den (x :: r) c) :
    ∃ c', c = x :: c' ∧ Tseq c' := by
  cases h with
  | @step _ c' _ _ h =>
    refine ⟨c', rfl, den_tseq h ?_⟩
    rcases hr with rfl | rfl | rfl | rfl <;> simp [isT]
  | skip _ => simp [isT] at hx
  | more _ _ _ => simp [isT] at hx

theorem subtree_shape {s : Step} {r : List Step} (h : subtreeTails.contains (s :: r) = true) :
    isT s = true ∧ (r = [] ∨ r = [.mark] ∨ r = [.mark, .n0] ∨ r = [.mark, .n2]) := by
  simp [subtreeTails] at h
  rcases h with h | h | h | h | h | h | h | h <;> (obtain ⟨rfl, rfl⟩ := h; simp [isT])

theorem extend_region {x : Step} {r : List Step} {s : Step} (hx : isT x = true) (hs : isCtor s = true) :
    extend (x :: r) s = [x, .mark, s] := by
  have hxm : (x == Step.mark) = false := by cases x <;> simp_all [isT]
  have hsm : (s == Step.mark) = false := by cases s <;> simp_all [isCtor]
  simp [extend, hxm, hx, hs, hsm]

/-- Extending a tree position by a constructor step keeps every concrete
    path: the fold with the marker loses no place. -/
theorem extend_sound : ∀ (p c : List Step) (s : Step), TreePos p = true → isCtor s = true →
    Den p c → Den (extend p s) (c ++ [s]) := by
  intro p
  induction p with
  | nil =>
    intro c s _ hs h
    cases h
    have : s ≠ .mark := by intro e; subst e; simp [isCtor] at hs
    exact .step s this .nil
  | cons x r ih =>
    intro c s hp hs h
    by_cases hx : x = .p0 ∨ x = .p1
    · have hx' : (x == Step.p0 || x == Step.p1) = true := by rcases hx with rfl | rfl <;> rfl
      have hr : TreePos r = true := by simpa [TreePos, hx'] using hp
      have hxm : x ≠ .mark := by rcases hx with rfl | rfl <;> simp
      have hxt : isT x = false := by rcases hx with rfl | rfl <;> rfl
      cases h with
      | step _ _ h =>
        have e : extend (x :: r) s = x :: extend r s := by
          have : (x == Step.mark) = false := by rcases hx with rfl | rfl <;> rfl
          simp [extend, this, hxt]
        rw [e]
        exact .step x hxm (ih _ s hr hs h)
      | skip _ => exact absurd rfl hxm
      | more _ _ _ => exact absurd rfl hxm
    · have hx' : (x == Step.p0 || x == Step.p1) = false := by
        rcases x <;> simp_all
      have ht : subtreeTails.contains (x :: r) = true := by simpa [TreePos, hx'] using hp
      obtain ⟨hxT, hr⟩ := subtree_shape ht
      obtain ⟨c', rfl, hc'⟩ := den_tail_tseq hxT hr h
      rw [extend_region hxT hs]
      have hxm : x ≠ .mark := by intro e; subst e; simp [isT] at hxT
      have hsm : s ≠ .mark := by intro e; subst e; simp [isCtor] at hs
      exact .step x hxm (den_mark_of hc' (.step s hsm .nil))

/-- `master`'s fold drops a place: the left subtree's list is not one of
    the paths `#Node.1` stands for. -/
theorem master_fold_unsound : extendMaster [.n0] .n1 = [.n1] ∧ ¬ Den [.n1] [.n0, .n1] := by
  refine ⟨rfl, ?_⟩
  intro h; cases h

/-- With the marker, it is kept. -/
theorem marker_fold_keeps : extend [.n0] .n1 = [.n0, .mark, .n1] ∧ Den [.n0, .mark, .n1] [.n0, .n1] :=
  ⟨rfl, .step _ (by decide) (.skip (.step _ (by decide) .nil))⟩

/-- The root's list and every list of the left subtree are two places, and
    neither overlaps nor holds the other; so are the two subtrees' lists. -/
theorem root_apart : ({} : Config).conflict [.n1] [.n0, .mark, .n1] = false := by decide

theorem sides_apart : ({} : Config).conflict [.n0, .mark, .n1] [.n2, .mark, .n1] = false := by decide

/-- A subtree holds its region's lists, and a deeper subtree holds some of
    them approximately. -/
theorem subtree_holds : ({} : Config).conflict [.n0] [.n0, .mark, .n1] = true ∧
    ({} : Config).conflict [.n0, .mark, .n0] [.n0, .mark, .n1] = true := by decide

end Ownership.Tree
