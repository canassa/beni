## 2026-10-30 21:02 CET — own2: widen opens a choice only where a knot returns

**What I did.** The review of #1363 found a precision loss. The first rule opened a branch join at a tree's
root whenever its place is on a cycle and the value holds any `⟲`. A `⟲` leaf (`π1⟲`, a parameter's
own deeper levels) was enough, so the commonest tree function, `case t of Node a xs b → Node a
(List.push xs 1) b; Leaf → Leaf`, lost its exact `res`, and its callers were refused (`gp t#Node.1`
disjoint). Now such a node is opened only when a **knot** returns to its path or above it: a built node of
the value (a `node` or a `delta`) at a `⟲`. A probe of the value before the walk finds the knots, once,
and only when a node needs the answer. §2.3 *On the cycle* says so. The fixture
`ownership/WidenChoiceLeafReentry` (`w1`, `gp`, `h`) checks v2 against v1 demand by demand. It fails on
the PR's first head and passes now, and so does a Shape unit test. Over the ownership and run corpus,
only `WidenChoiceRoot`'s summary differs from master. The two summaries that the first rule changed are
back to master's.

On `own2-s3b4a` with the new rule, the groups still settle (`incAll` 4 walks, `incAll2` 4, `incLeft` 3,
`build`/`dup` 3). `LevelFresh.pushRoot` and `FoldLevels.pushRoot` are still refused. Their cause is not a
leaf: `build` is really recursive, and widen keys a `⟲` to its ancestor's class.

**What I learned.** The self-map over n children costs 7.0k / 11.7k / 24.8k / 50.8k (+14.6k growth) at
n = 1/2/4/8, and n = 16 reaches `ownership_summary_size`. Widen's share of that (`Cond.widenValue`, so the
shape fold plus the primitive plus `propagate`) is 2.8k / 5.2k / 12.1k / 34.2k. For each node and edge
that widen walks, the cost grows only by a log factor (46 / 50 / 56 / 61 records). What grows is the
input: 61 / 103 / 217 / 565 nodes and edges over the 7 widens, because each of the n call results is
forced as its own view with n children, so widen sees about n² edges. That is the graft's representation, and it is for 4a. Also
#1373: a node shared under both sides of an opened union leaves its child classes unfolded, so no
obligation is stored for them, though the primitive counts them twice.
