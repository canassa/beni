import Ownership.Syntax

namespace Ownership

/-- Deliberate checker holes. Each is a required negative control: the oracle
    must find an accepted disagreement under it (`ownership controls`), and a
    fixture must disagree under it and be rejected by the unmutated checker. -/
inductive Mutant where
  | disjoint            -- a write ignores other operand paths (Disjoint dropped)
  | borrowedSupply      -- traversal treats a borrowed source's elements as owned
  | traversalExclusive  -- a consuming list traversal skips its exclusive-source demand
  | manyCalls           -- a traversal step may consume a capture on every iteration
  | copyExclusive       -- `copy` marks its shallow result exclusive
  | closeSource         -- `close` forgets the map source's provenance
  | keepsShape          -- focus keeps exclusivity without checking "keeps shape"
  -- Rows of the summary layer (thesis §3.7, §4.5–§4.7).
  | guardReuse          -- a cached summary is reused without re-asking its guards
  | callbackXres        -- a callback result's containers are taken as exclusive (T59's row)
  | supplyEdge          -- a callback may write a supply that is not owned (W ⇒ owned dropped)
  | supplyRecheck       -- an owned supply is not re-checked where its scope ends (T46's row)
  | callsEdge           -- a once callback may be called many times (calls ≤ 1 dropped)
  deriving Repr, BEq, Inhabited

def Mutant.all : List Mutant :=
  [.disjoint, .borrowedSupply, .traversalExclusive, .manyCalls, .copyExclusive,
   .closeSource, .keepsShape, .guardReuse, .callbackXres, .supplyEdge, .supplyRecheck,
   .callsEdge]

def Mutant.name : Mutant → String
  | .disjoint => "disjoint" | .borrowedSupply => "borrowed-supply"
  | .traversalExclusive => "traversal-exclusive" | .manyCalls => "many-calls"
  | .copyExclusive => "copy-exclusive" | .closeSource => "close-source"
  | .keepsShape => "keeps-shape" | .guardReuse => "guard-reuse"
  | .callbackXres => "callback-xres" | .supplyEdge => "supply-edge"
  | .supplyRecheck => "supply-recheck" | .callsEdge => "calls-edge"

def Mutant.parse (s : String) : Option Mutant := Mutant.all.find? (·.name == s)

/-- Mutants of the summary layer's rows: inert in the per-call checker. -/
def Mutant.summaryRow : Mutant → Bool
  | .guardReuse | .callbackXres | .supplyEdge | .supplyRecheck | .callsEdge => true
  | _ => false

structure Config where
  oldFreshRule : Bool := false
  dropTraversalEscapes : Bool := false -- negative control for the original defect
  mutant : Option Mutant := none
  /-- Check with the frozen per-call re-inference checker instead (cross-check). -/
  reinfer : Bool := false
  inferenceFuel : Nat := 200
  rounds : Nat := 24
  deriving Repr, Inhabited

def Config.has (c : Config) (m : Mutant) : Bool := c.mutant == some m

end Ownership
