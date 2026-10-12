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
  | callbackWrites      -- a callback's W on an argument is not published as W
  | callbackAliases     -- a callback's result forgets the arguments it returns
  | callbackEnv         -- a callback's result forgets its environment
  | callbackEscapes     -- a callback's E on an argument is dropped
  | callbackRequires    -- a callback's xreq on an argument is not published
  | requiresEdge        -- xreq ⇒ exclusive supply is not checked
  | forwardGuards       -- a callee's guards on our own input are not re-asked
  | transferSupplies    -- a callee's supplies to our own input are dropped
  | onceThroughCall     -- a once callback called by a callee is not consumed at the call
  -- Liveness (summary checker only).
  | branchLive          -- liveness ignores the nonzero arm of a conditional
  deriving Repr, BEq, Inhabited

def Mutant.all : List Mutant :=
  [.disjoint, .borrowedSupply, .traversalExclusive, .manyCalls, .copyExclusive,
   .closeSource, .keepsShape, .guardReuse, .callbackXres, .supplyEdge, .supplyRecheck,
   .callsEdge, .callbackWrites, .callbackAliases, .callbackEnv, .callbackEscapes,
   .callbackRequires, .requiresEdge, .forwardGuards, .transferSupplies, .onceThroughCall, .branchLive]

def Mutant.name : Mutant → String
  | .disjoint => "disjoint" | .borrowedSupply => "borrowed-supply"
  | .traversalExclusive => "traversal-exclusive" | .manyCalls => "many-calls"
  | .copyExclusive => "copy-exclusive" | .closeSource => "close-source"
  | .keepsShape => "keeps-shape" | .guardReuse => "guard-reuse"
  | .callbackXres => "callback-xres" | .supplyEdge => "supply-edge"
  | .supplyRecheck => "supply-recheck" | .callsEdge => "calls-edge"
  | .callbackWrites => "callback-writes" | .callbackAliases => "callback-aliases"
  | .callbackEnv => "callback-env" | .callbackEscapes => "callback-escapes"
  | .callbackRequires => "callback-requires" | .requiresEdge => "requires-edge"
  | .forwardGuards => "forward-guards" | .transferSupplies => "transfer-supplies"
  | .onceThroughCall => "once-through-call"
  | .branchLive => "branch-live"

def Mutant.parse (s : String) : Option Mutant := Mutant.all.find? (·.name == s)

/-- Mutants the generator need not catch within one campaign: `callback-escapes`
    and `forward-guards` are caught rarely or not at all (generator v5: 2 and
    0 seeds of 3) and are required through their fixed probe; `callback-requires`, `requires-edge` and
    `transfer-supplies` changed no verdict in 20000 trials and have no probe —
    known gaps (COVERAGE.md). `ownership controls` reports all five. -/
def Mutant.generatorOptional : Mutant → Bool
  | .callbackEscapes | .callbackRequires | .requiresEdge | .forwardGuards | .transferSupplies => true
  | _ => false

/-- Mutants of the summary layer's rows, and `branch-live`, which only the
    summary checker implements: inert in the per-call checker. -/
def Mutant.summaryRow : Mutant → Bool
  | .guardReuse | .callbackXres | .supplyEdge | .supplyRecheck | .callsEdge | .callbackWrites
  | .callbackAliases | .callbackEnv | .callbackEscapes | .callbackRequires | .requiresEdge
  | .forwardGuards | .transferSupplies | .onceThroughCall | .branchLive => true
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
