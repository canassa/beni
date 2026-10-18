import Ownership.Tree.Syntax

/-! # Paths with the level marker

`ownership-checker.md` §16.7, the amendment "the level marker `⟨T⟩` replaces
(d)" (2026-10-18). The region of `Tree` that holds a position starts at its
first subtree step `s₀` (`#Node.0` or `#Node.2`); a constructor step added
inside a region goes on from that first step, under the marker:
`#Node.0#Node.1` is `#Node.0⟨Tree⟩#Node.1`, every list of the left subtree, its
root's included, and `#Node.0⟨Tree⟩#Node.0#Node.1` is `#Node.0⟨Tree⟩#Node.1`.
`#Node.1` with no marker is the root's own list and nothing else.

`Config` also carries the deliberate holes the enumerator must catch:
`marker := false` is `master`'s fold onto the region's start (`#Node.0#Node.1`
is `#Node.1`) with #341's projection, which keeps every entry whose first step
is a constructor step of `Tree`; `levelSep := false` drops the call-site
condition between two paths of one parameter (`paramHole`); `approx := false`
drops the approximate holding past a marker. -/

namespace Ownership.Tree

structure Config where
  marker : Bool := true
  levelSep : Bool := true
  approx : Bool := true
  deriving DecidableEq, Repr, Inhabited

/-- A step into a value of `Tree`: the subtree fields. -/
def isT : Step → Bool
  | .n0 | .n2 => true
  | _ => false

/-- A constructor step of `Tree`. -/
def isCtor : Step → Bool
  | .n0 | .n1 | .n2 => true
  | _ => false

/-- The fold with the marker. A path is a run of pair steps, then a tree
    segment: `[]`, `[n1]`, `[s₀]`, `[s₀, ⟨T⟩]` or `[s₀, ⟨T⟩, s]`. A constructor
    step or a marker added after the region's first step `s₀` goes on from
    `s₀ ⟨T⟩`; one added after a marker at the root folds onto it. -/
def extend : List Step → Step → List Step
  | [], s => [s]
  | x :: rest, s =>
    if x == .mark then
      if isCtor s || s == .mark then .mark :: (if s == .mark then [] else [s]) else x :: rest ++ [s]
    else if isT x then
      if isCtor s || s == .mark then x :: .mark :: (if s == .mark then [] else [s]) else x :: rest ++ [s]
    else x :: extend rest s

/-- `master`'s fold (the hole): a constructor step added inside a region goes
    on from where the path entered `Tree`, so `#Node.0#Node.1` is `#Node.1`. -/
def extendMaster : List Step → Step → List Step
  | [], s => [s]
  | x :: rest, s =>
    if isT x && isCtor s then [s] else x :: extendMaster rest s

def Config.extend (c : Config) (p : List Step) (s : Step) : List Step :=
  if c.marker then Ownership.Tree.extend p s else extendMaster p s

/-- The path `s :: p`, folded: an entry of a field's value moved into the
    constructed value. -/
def Config.prefixWith (c : Config) (s : Step) (p : List Step) : List Step :=
  p.foldl c.extend [s]

/-- Overlap: equal steps are compared on; a marker against any step
    overlaps, as `⋆` does; a prefix overlaps (a holder and what it holds). -/
def overlap : List Step → List Step → Bool
  | [], _ => true
  | _ :: _, [] => true
  | a :: p, b :: q => if a == b then overlap p q else a == .mark || b == .mark

/-- `o` holds part of `i` approximately: they first differ after both have
    passed the same marker, and `o`'s step there is a subtree step (whose
    field can hold `Tree`). `#Node.0⟨Tree⟩#Node.0` holds some of
    `#Node.0⟨Tree⟩#Node.1`. -/
def approxHolds (passed : Bool) : List Step → List Step → Bool
  | a :: o, b :: i => if a == b then approxHolds (passed || a == .mark) o i else passed && isT a
  | _, _ => false

/-- Two paths of one value may name storage of each other: overlap, or
    approximate holding in either direction. -/
def Config.conflict (c : Config) (p q : List Step) : Bool :=
  overlap p q || (c.approx && (approxHolds false p q || approxHolds false q p))

end Ownership.Tree
