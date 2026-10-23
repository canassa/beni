## 2026-10-23 03:53 CEST — only recursive types fold (§16.7 (a))

**What I did.** Took up #286's order (a), (d), (e), (c). Found that (a), folding only a type
that reaches itself, was already built inside F2 (#748, `b5caf1495`): `childRaw` returns a plain
step for a constructor of a type that `typeRecursive` says does not reach itself. The spec
still called (a) "not yet built". Wrote `ownership/Nest` with `pushInner`, `caller`, `local` and
`apart`, proved it red by restoring the old head fold in a scratch build (`caller`'s call went
back to `accepted param`), and recorded (a) as built in a dated amendment of §16.7 with its
soundness and finiteness arguments and the superseded paragraphs named.

**What I learned.** The old fold was unsound in the same way as F1's first form: it made one
place a prefix of another, and a deep condition does not compare a container with what it holds,
so a holder was lost. The Schema measurements that held (a) back were all cast growth, which F2's
full-type marker now folds; core's two tests already pin that core refuses nothing.
