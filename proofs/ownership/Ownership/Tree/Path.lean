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
drops the approximate holding past a marker; `starOverlap := true` keeps
5120ba491's overlap, where a marker overlaps any step (sound, coarser);
`canonical := false` writes a summary's facts in the expanded form instead of
`P⟨T⟩r`; `exclReliance := false` refuses a call whose condition joins two
places of one argument subvalue instead of requiring the caller's
exclusivity (#399); `checkExcl := false` records that requirement and never
checks it (a hole). -/

namespace Ownership.Tree

structure Config where
  marker : Bool := true
  levelSep : Bool := true
  approx : Bool := true
  starOverlap : Bool := false
  canonical : Bool := true
  exclReliance : Bool := true
  checkExcl : Bool := true
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

/-- Overlap, exact (§16.7's amendment at 161f77eea). Equal steps are
    compared on. At the first index where one path has the marker `⟨T⟩r` and
    the other does not: they overlap when the other ends there (a prefix,
    handled by the first two arms), when its step there is a region step (a
    subtree step: the marker's expansion may begin with it), or when `r`
    overlaps it from there (the empty expansion: in this fragment every
    marker stands at a position whose value is a `Tree`). Fuel bounds the
    two lengths; out of fuel it answers `true`. -/
def overlapF : Nat → List Step → List Step → Bool
  | 0, _, _ => true
  | _ + 1, [], _ => true
  | _ + 1, _ :: _, [] => true
  | f + 1, a :: p, b :: q =>
    if a == b then overlapF f p q
    else if a == .mark then isT b || overlapF f p (b :: q)
    else if b == .mark then isT a || overlapF f (a :: p) q
    else false

def overlap (p q : List Step) : Bool := overlapF (p.length + q.length + 1) p q

/-- The overlap of 5120ba491, kept as a variant: a marker against any step
    overlaps, as `⋆` does. -/
def overlapStar : List Step → List Step → Bool
  | [], _ => true
  | _ :: _, [] => true
  | a :: p, b :: q => if a == b then overlapStar p q else a == .mark || b == .mark

/-- `o` holds `i` (`covers`, `levelHolds`, at 161f77eea): exactly when `o` is a
    prefix of `i`; approximately when, at the first index where they differ,
    `i` has a marker and `o`'s step is a region step or `o` holds `i`'s rest
    after the marker; or `o` has a marker and `i`'s step is a region step or
    `o`'s rest after the marker holds `i`; or both passed the same marker
    just before (`passed`) and `o`'s step is a subtree step. -/
def holdsF : Nat → Bool → List Step → List Step → Bool
  | 0, _, _, _ => true
  | _ + 1, _, [], _ => true
  | _ + 1, _, _ :: _, [] => false
  | f + 1, passed, a :: o, b :: i =>
    if a == b then holdsF f (a == .mark) o i
    else if b == .mark then isT a || holdsF f false (a :: o) i
    else if a == .mark then isT b || holdsF f false o (b :: i)
    else passed && isT a

/-- Holding exactly: a prefix. -/
def isPrefix : List Step → List Step → Bool
  | [], _ => true
  | _ :: _, [] => false
  | a :: o, b :: i => a == b && isPrefix o i

def holds (o i : List Step) : Bool := holdsF (o.length + i.length + 1) false o i

/-- Two paths of one value may name storage of each other: they overlap, or
    one holds the other. With `approx := false` holding is exact only. -/
def Config.conflict (c : Config) (p q : List Step) : Bool :=
  (if c.starOverlap then overlapStar p q else overlap p q) ||
  (if c.approx then holds p q || holds q p else isPrefix p q || isPrefix q p)

end Ownership.Tree
