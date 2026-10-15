import Ownership.Syntax

namespace Ownership

/-- Deliberate checker holes. Each is a required negative control: the oracle
    must find an accepted disagreement under it (`ownership controls`), and a
    fixture must disagree under it and be rejected by the unmutated checker. -/
inductive Mutant where
  | earlyErr -- an Err constructor drops its payload provenance
  | recursivePayload -- Link drops its recursive payload provenance
  | initRetained -- an entry omits other retained fields
  | initFrame -- a callee borrows the module initializer's transfer authority
  | initAuthority -- a nested entry reuses spent private-transfer authority
  | initShared -- an entry transfers exported/shared initialization cells
  | armResult          -- terminal arm reads are omitted from enclosing liveness
  | blockResult        -- terminal block reads are omitted from enclosing liveness
  | captureRead        -- closure creation does not read captured paths
  | foldLoan           -- a taken element loses its source condition on feedback
  | recursiveCapture   -- recursion substitutes an empty captured environment
  | calleeCapture      -- call disjointness ignores the callee environment
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
  | branchClosure       -- liveness ignores the captures of closures a conditional arm creates
  | shadowing           -- shadowing is allowed and a let resolves its continuation's uses inside
  -- Escapes.
  | sharedRoots         -- `shared` escapes only the spine of its operand, not what it contains
  | sharedFn            -- `shared` does not escape cells captured by a closure held in a record field
  -- Counting.
  | manyOff             -- a traversal step that calls a callback once is not counted as many calls
  -- Scope (probe only: no typed program has an unbound live variable).
  | noScope             -- an unbound live variable is read as dead instead of refused
  -- Fifth review.
  | setExclusive        -- `set` keeps a list exclusive whatever it stores
  | resultPositions   -- ignore retained captures beside written accumulator paths
  | prependBase       -- forget the base read/possible backing alias
  | constructorArgs   -- a constructor-like record forgets its payload
  | eventCapture      -- an event-slot projection forgets handler captures
  | taggerNeed        -- an owned-result boundary trusts a shared result
  | captureEmpty      -- a retained callback's nonempty environment is ignored
  | forwardNeed       -- a callback-produced result is assumed owned
  | foldInvariant     -- grant separation to every accumulator
  | modelInvariant    -- grant separation to every model at entry
  | branchEscapes       -- a branch drops escapes from before the case
  | onceLive            -- liveness drops the capture paths of once closures
  -- Constructions and views (the oracle review, 2026-10-15).
  | constructDisjoint   -- a construction's Disjoint ignores its other operands
  | viewAlias           -- a list pattern's spread binding forgets its source
  deriving Repr, BEq, Inhabited

def Mutant.all : List Mutant :=
  [.initFrame, .initAuthority, .earlyErr, .recursivePayload, .initRetained, .initShared, .armResult, .blockResult, .captureRead, .foldLoan, .recursiveCapture, .calleeCapture, .disjoint, .borrowedSupply, .traversalExclusive, .manyCalls, .copyExclusive,
   .closeSource, .keepsShape, .guardReuse, .callbackXres, .supplyEdge, .supplyRecheck,
   .callsEdge, .callbackWrites, .callbackAliases, .callbackEnv, .callbackEscapes,
   .callbackRequires, .requiresEdge, .forwardGuards, .transferSupplies, .onceThroughCall, .branchLive,
   .branchClosure, .shadowing, .sharedRoots, .sharedFn, .manyOff, .noScope, .setExclusive, .onceLive, .branchEscapes, .prependBase, .constructorArgs, .eventCapture, .resultPositions,
   .taggerNeed, .captureEmpty, .forwardNeed, .foldInvariant, .modelInvariant, .constructDisjoint, .viewAlias]

def Mutant.name : Mutant → String
  | .initFrame => "init-frame"
  | .initAuthority => "init-authority"
  | .earlyErr => "early-err" | .recursivePayload => "recursive-payload"
  | .initRetained => "init-retained" | .initShared => "init-shared"
  | .armResult => "arm-result" | .blockResult => "block-result"
  | .captureRead => "capture-read" | .foldLoan => "fold-loan"
  | .recursiveCapture => "recursive-capture" | .calleeCapture => "callee-capture"
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
  | .branchLive => "branch-live" | .branchClosure => "branch-closure"
  | .shadowing => "shadowing" | .sharedRoots => "shared-roots"
  | .sharedFn => "shared-fn" | .manyOff => "many-off" | .noScope => "no-scope"
  | .resultPositions => "result-positions"
  | .prependBase => "prepend-base" | .constructorArgs => "constructor-args"
  | .eventCapture => "event-capture" | .taggerNeed => "tagger-need"
  | .captureEmpty => "capture-empty" | .forwardNeed => "forward-need"
  | .foldInvariant => "fold-invariant" | .modelInvariant => "model-invariant"
  | .branchEscapes => "branch-escapes"
  | .setExclusive => "set-exclusive" | .onceLive => "once-live"
  | .constructDisjoint => "construct-disjoint" | .viewAlias => "view-alias"

def Mutant.parse (s : String) : Option Mutant := Mutant.all.find? (·.name == s)

/-- The sync grammar, rather than the legacy random generator, must catch
    these controls. Main enforces every one in CI and `controls`. -/
def Mutant.enumeratorRequired : Mutant → Bool
  | .initFrame => true
  | .constructDisjoint | .viewAlias => true
  | .initAuthority => true
  | .earlyErr | .recursivePayload | .initRetained | .initShared => true
  | .armResult | .blockResult | .captureRead | .foldLoan | .recursiveCapture | .calleeCapture => true
  | .resultPositions | .branchEscapes | .prependBase | .constructorArgs | .eventCapture
  | .taggerNeed | .captureEmpty | .forwardNeed | .foldInvariant | .modelInvariant => true
  | _ => false

/-- Mutants the generator need not catch: `callback-requires`, `requires-edge`
    and `transfer-supplies` change no verdict on any generated program and are
    argued equivalent in this core (COVERAGE.md, "Equivalent (argued)");
    `no-scope` cannot be reached by a typed program and is required through its
    checker-level probe. `ownership controls` reports all four. -/
def Mutant.generatorOptional : Mutant → Bool
  | .initFrame => true
  | .constructDisjoint | .viewAlias => true
  | .initAuthority => true
  | .earlyErr | .recursivePayload | .initRetained | .initShared => true
  | .armResult | .blockResult | .captureRead | .foldLoan | .recursiveCapture | .calleeCapture => true
  | .callbackRequires | .requiresEdge | .transferSupplies => true
  | .resultPositions | .noScope | .branchEscapes | .prependBase | .constructorArgs | .eventCapture
  | .taggerNeed | .captureEmpty | .forwardNeed | .foldInvariant | .modelInvariant => true
  | _ => false

/-- Mutants of the summary layer's rows, and `branch-live`, which only the
    summary checker implements: inert in the per-call checker. -/
def Mutant.summaryRow : Mutant → Bool
  | .initFrame => true
  | .constructDisjoint | .viewAlias => true
  | .initAuthority => true
  | .earlyErr | .recursivePayload | .initRetained | .initShared => true
  | .armResult | .blockResult | .captureRead | .foldLoan | .recursiveCapture | .calleeCapture => true
  | .guardReuse | .callbackXres | .supplyEdge | .supplyRecheck | .callsEdge | .callbackWrites
  | .callbackAliases | .callbackEnv | .callbackEscapes | .callbackRequires | .requiresEdge
  | .forwardGuards | .transferSupplies | .onceThroughCall | .branchLive | .branchClosure
  | .resultPositions | .prependBase | .constructorArgs | .eventCapture | .taggerNeed | .captureEmpty
  | .forwardNeed | .foldInvariant | .modelInvariant | .branchEscapes | .shadowing | .sharedRoots | .sharedFn | .manyOff | .noScope | .setExclusive | .onceLive => true
  | _ => false

structure Config where
  oldFreshRule : Bool := false
  dropTraversalEscapes : Bool := false -- negative control for the original defect
  mutant : Option Mutant := none
  /-- Check with the frozen per-call re-inference checker instead (cross-check). -/
  reinfer : Bool := false
  bridgeTrace : Bool := false -- observations only; no ownership rule changes
  shapeOnly : Bool := false -- internal provenance pass; never used for acceptance
  inferenceFuel : Nat := 200
  rounds : Nat := 24
  deriving Repr, Inhabited

def Config.has (c : Config) (m : Mutant) : Bool := c.mutant == some m

end Ownership
