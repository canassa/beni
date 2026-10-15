## 2026-09-22 01:03 CEST — queue rows 57 and 59: a thunk where a value belonged, and a bound with a number behind it

**What I did**

- **Row 57**, the last exit-0 path to a runtime exception in the queue.
  `pub blank : List a where a.eq : a, a -> Bool` / `blank = []` built with exit
  0 and threw `TypeError` at load. A reference to a constrained value is its
  eta-expansion (spike A.25), and at beni arity 0 an eta-expansion is a
  **thunk**: `blankInts = () => blank(eq$prim)`, handed to `List.length`, while
  every consumer reads the name as the list it is annotated to be. One branch
  in `Lower.etaExpand` — at arity 0 the expansion is the call. Spec first: §8.1,
  §8.2/A.25 and §10.10 corrected, A.85 appended. `run/ConstrainedConstant` is
  the fixture, and with the branch reversed it is the **only** test that fails.
- **Row 59**, the flaky 60 s bound on the 5 000-module abuse case. Now per-run:
  60 s everywhere, 300 s for the one case whose input is 5 000 files.
- Rows 57 and 59 closed; all three gates green on darwin.

**What I learned**

- **The spec was wrong in two places, and the second one is why nobody caught
  the first.** §8.1 said a zero-parameter constrained declaration is refused by
  the checker "so the backend never meets one". §10.10 explained at length why
  the INFERRED case is refused — and said nothing about the annotated case
  except that this code does not apply to it. Each section was locally coherent;
  the hole was in the space between them, and it is exactly the space the
  emitter walked into. When a document says another phase already handled
  something, that sentence is a claim needing a test, not a fact.
- **Rule 7 settled the fork cleanly, and it was not the smaller diff.** Refusing
  the annotated constant would have been fewer lines than fixing the emitter,
  and it was the wrong answer: both close the same hole, so the refusal buys no
  guarantee and costs `Dict.empty` — a polymorphic constant carrying a
  requirement is a shape anyone would want, and forcing it to grow a dummy
  parameter is the "you should not need that" rule 7 rejects. The test for a
  restriction is what guarantee it buys, and here the answer was *none*.
- **A.25's reason did not say what I first read it as saying.** "A function-typed
  value in flight must be a closure of known arity" is a claim about
  FUNCTION-typed values. A constant is not one, so the closure was never an
  arity fix that happened to be wrong at 0 — it was the emitter writing a type
  error. The giveaway that the fix is right: **no `emit/` golden moved**, because
  every eta-expansion that already existed had arity above zero.
- **I recommended the wrong mechanism for row 59 and had to withdraw it.** Cpu
  time is the right thing to bound, but reading a LIVE child's cpu time needs
  per-pid rusage (`proc_pid_rusage` on macOS, `/proc/<pid>/stat` on Linux),
  neither is in std, and `getrusage(RUSAGE_CHILDREN)` only counts children
  already reaped — it says nothing about the run being bounded. Two non-portable
  syscalls inside a test harness is a worse trade than a per-case wall-clock
  bound. The numbers and that reasoning are in the harness doc comment so the
  next person does not re-derive them.
- **Two sessions were writing this repo at once.** A concurrent session appended
  the 00:48 and 01:01 entries above and the schema decisions in the queue while
  I was fixing rows 57 and 59. Nothing collided — its work is design records, mine
  is code — but I committed my code separately first and left its files alone
  until the owner said to proceed. Worth knowing the diary and the queue are the
  two files where that can bite.
- **Still not run on Linux**, both rows included.
