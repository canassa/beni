## 2026-10-24 17:54 CEST — a value read next, after reads alone

**What I did.** #934 item 4, in E1's form from the hand-minify pass, with the assignment case the
#936 lane asked for. `Opt` now writes a value read once in the next statement at that read, when
everything evaluated before the read is a read: a name nothing rebinds, a literal, a field read,
an index read. A value lowering keeps for an effect moves past names and literals only. A read in
a branch, after a call, operator or template, or after an earlier write in a sequence is
refused. So `n(a[5],fa(b.b,b.d))` and the listener `a=>{b.a=I(a);u(c[0])}`. Spec first:
`backend.md` §9 item 1. A new `Opt` unit test pins each refusal. 61 `emit/` goldens moved (red
with the change taken out), all shorter raw. S1: N = 1 −17 / −5 / −8, N = 16 −46 / −71 / −54,
slope 64→256 −1.2 / −0.8 / −1.3 B/widget. `./rr check` 24/24.

**What I learned.** `run/QuestionOrder` caught a lost `Debug.log` in the first version. A binding
that `Spec` makes from a listed one (the `chain.2` call, after its `Result` is folded) can hold
an impure call and still not be listed (#944). Master is right only because that binding's one
read sits in a binding `Opt` drops after counting the read. Moving the call into the dropped
binding lost it. The fold now keeps any statement it moves a call into, as the binding was kept.
#944 owns the table defect itself. The handler case needed `.assign` and `.sequence` as read
positions. E2 writes the arm's stores as one sequence expression. A first version also folded back a
chain that lowering had spilled to bound its nesting, and Node could not parse the widest `++`
chain of `abuse_wide_test`. The fold now stops at `JsIr.nesting.spill`.
