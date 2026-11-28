## 2026-11-27 07:41 CET — v3 group 5: a call whose arguments are not apart

**What I did.** Worked on the seven `browser-inline` pages of #2657's group 5 under
`--ownership=v3`. One step is written and not landed: where a call's arguments are not apart,
the callee's claims are now lost only at the result entries that can hold a cell at two places
of the arguments (`Frame.argsDuplicated`, `holdsDuplicated`; kernel §4.4, *The claims of a call
whose arguments are not apart*). It takes the `element` refusal off `FoldRight`, `DictFoldLeft`
and `DictFoldRight`, but all three stay refused (`disjoint`), so the step wins no page. It is on
the local branch `own3-prec228-step`, not on `own3-prec228`.

**What I learned.**
- The fold pages have two causes. The first is above. The second is §3.4's wide reading: a
  fold's accumulator is a type variable of the fold, so the callback's parameter, and the cells
  an earlier run answered, is read at every location of the caller's dictionary. A list one run
  made is then at the dictionary's storage too, and the answer is `linear` nowhere. A two-line
  probe (a fold over `[ ( 0, 5 ), ( 0, 6 ) ]` into a dictionary of lists, then a write) is
  refused for this alone. To fix it, a walked body that does not cast needs a contract fact that
  says it hands a value at a type variable on whole, so that a caller can pair its parts by place
  (`paired_exact`, which only a cell's row has today). A row that rebuilds at a variable
  (research report 156) is the case that fact must exclude.
- A per-entry test makes more results `linear`, and that costs work later in a chain.
  `check_test`'s record chain went past its budget until the test ran only where two arguments
  hold cells and the set is small.
- `BracketInUpdate` needs the order of a callee's runs: `acquire` reads `model.count` and `use`
  writes it. Inside one call, nothing says that `bracket` runs `acquire` before `use` and never
  after it.
- `FunctionElements` and `ReturnedValidator` need a contract for functions held at a location
  of a container. `Contract.Fn` covers function parameters only.
- `TotalCallBranchOwnership` needs a lowering fact about when `inline` evaluates a hole. The
  safe values (pure and total) are evaluated at their write, after every unsafe value of the
  same binding function (browser-inline.md §8.2, *Evaluation order*). So "a hole is evaluated
  where it stands" is false for some holes, and it is false for markup that a `let` names.
