-- Keep witness reductions in one import chain so generated private splitters stay available.
import Ownership.LinkedWriteValid

/-! `LinkedWriteValid.linksValid_after_writeLinked` at two reachable states, from
the review of PR #314 (note 2): the two-component state of `LinkedWriteInstance` (a write through a
view whose source is dead), and a chain `xs ← rest ← tl` written through the
inner view `tl`, so the splice climbs two levels and the refresh comes back
down. For the chain, the theorem's conclusion is compared with the real
post-state, and `shorten_breaks` shows the non-shortening hypothesis is needed.
This module follows `LinkedWriteValid` in the import chain because it uses its
theorem; `LinkedWriteInstance` precedes it. -/

namespace Ownership.LinkedWriteValidInstance

open InPlaceSemantics Soundness

set_option maxRecDepth 100000

/-- The two-component state: the push of `rest` writes `[2, 9]`. -/
theorem pair_valid_after : LinksValid LinkedWriteInstance.hsAfter :=
  LinkedWriteValid.linksValid_after_writeLinked LinkedWriteInstance.invariant.linksValid
    (by intro old h; simp [LinkedWriteInstance.hs] at h; subst h; decide) LinkedWriteInstance.write_run

/-! ## A chain of two views, written through the inner one

`xs = [1, 2, 3]` at 0; `rest = view xs` (`[2, 3]`) at 1; `tl = view rest`
(`[3]`) at 2; then `push tl 9`. -/

def lit : Expr := .prim (.literal .int) [.int 1, .int 2, .int 3]
def chainMain : Expr :=
  .letE 0 lit (.letE 1 (.prim (.view true) [.var 0]) (.letE 2 (.prim (.view true) [.var 1])
    (.letE 3 (.prim .push [.var 2, .int 9]) (.prim .length [.var 3]))))
def chainProgram : Program := { main := chainMain }

#guard (check chainProgram).isOk
#guard match ValueSemantics.run chainProgram 1000, InPlaceSemantics.run chainProgram 1000 with
  | .ok t, .ok t' => t.finalValue == .int 2 && t'.finalValue == t.finalValue
  | _, _ => false

def chainPre : State :=
  { fuel := 10, heap := #[[.int 1, .int 2, .int 3], [.int 2, .int 3], [.int 3]],
    links := [(1, 0, true), (2, 1, true)] }

theorem chain_reached :
    (InPlaceSemantics.eval 1000 [] none []
      (.letE 0 lit (.letE 1 (.prim (.view true) [.var 0]) (.letE 2 (.prim (.view true) [.var 1])
        (.atom (.int 0)))))).run { fuel := 1000 } =
      .ok (.int 0, { chainPre with fuel := 993 }) := by cbv

theorem chain_valid : LinksValid chainPre := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro v s f member
    simp only [chainPre, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
    rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ <;> decide
  · intro v s f member
    simp only [chainPre, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
    rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩
    · exact ⟨[.int 1, .int 2, .int 3], rfl, by simp⟩
    · exact ⟨[.int 2, .int 3], rfl, by simp⟩
  · decide
  · intro v s f member
    simp only [chainPre, List.mem_cons, Prod.mk.injEq, List.not_mem_nil, or_false] at member
    rcases member with ⟨rfl, rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩
    · exact ⟨[.int 1, .int 2, .int 3], rfl, rfl⟩
    · exact ⟨[.int 2, .int 3], rfl, rfl⟩

/-- The real linked write of `push tl 9`: the splice writes `rest` to
    `[2, 3, 9]` and `xs` to `[1, 2, 3, 9]`; the refresh rewrites both views. -/
def chainPost : State :=
  { chainPre with heap := #[[.int 1, .int 2, .int 3, .int 9], [.int 2, .int 3, .int 9], [.int 3, .int 9]] }

theorem chain_write : (writeLinked 2 [.int 3, .int 9]).run chainPre = .ok (.ref 2, chainPost) := by cbv

theorem chain_valid_after : LinksValid chainPost :=
  LinkedWriteValid.linksValid_after_writeLinked chain_valid (by intro old h; simp [chainPre] at h; subst h; decide) chain_write

/-- The conclusion is the real one: the theorem's contents clause at the
    outer link agrees with the computed heap. -/
theorem chain_outer_contents : chainPost.heap[1]? = some (viewOf true [.int 1, .int 2, .int 3, .int 9]) := rfl

/-- The non-shortening hypothesis is needed: a write that shortens a source
    of a view leaves a state that `LinksValid` refuses. `xs` written to `[1]`
    through a plain `set!` makes `rest` (`[2, 3]`) stale. -/
theorem shorten_breaks : ¬ LinksValid { chainPre with heap := #[[.int 1], [.int 2, .int 3], [.int 3]] } := by
  intro h
  obtain ⟨source, hs, hv⟩ := h.contents 1 0 true (by simp [chainPre])
  simp at hs
  subst hs
  simp [viewOf] at hv


end Ownership.LinkedWriteValidInstance
