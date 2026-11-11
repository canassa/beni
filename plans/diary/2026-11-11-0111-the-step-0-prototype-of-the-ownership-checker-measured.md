## 2026-11-11 01:11 CET — the step 0 prototype of the ownership checker, measured (#2465, #2451)

**What I did.** Worker `ownership-step0`. The owner asked on pull request #2451 for the step 0 prototype
of research report 110, and for a decision with measurements. The prototype is `src/own3/` (5 files, 5 156
lines) behind the hidden flag `--ownership=v3`. It is for lists only. It takes v2's place graph, pre-pass,
report and lowering channel by import, and it changes no file of v1 or v2. Research report 111 has the
design as built, the measurements and the verdict "go, with changes". On the 32 real roots the prototype
accepts 299 of the 308 list writes that v1 judges, with no refusal at another position. It runs at
1 049 000 lines per second on the modules that v2 walks (v2: 119 000, v1: 147 000). Three scripts are new
or changed: `bench/ownership-v2-review.mjs --checkers=v1,v2,v3`, `bench/ownership-step0-sanitiser.mjs`
and `bench/ownership-step0-generator.mjs` (two families of programs). Four black-box tests are new in
`tests/blackbox/check_test.zig`.

**What I learned.**

- The count of accepted real writes says nothing about soundness. The count was 299 when the first full
  run of the sanitiser corpus started. That run found 19 programs that the prototype accepted and must
  refuse: 18 trap, and one prints a different text. Run the 345 fixtures before each claim. One run takes 20
  seconds on a ReleaseFast compiler.
- "A forgotten case gives `shared`, which refuses" is true for a value and false for a function value. A
  fact that is missing from the contract of a function parameter gives an accepted write. 16 of the 19
  programs were of this kind: an answer that lost what it holds, an answer that escapes in the callee, a
  function that keeps what the callee changes later, and two parts of one handed value.
- A `shared` location must keep its sources in each place that makes one. The first fix was in the walk.
  The same fault was in the answer of a known function, and in the supply of a function parameter.
- "A write makes a new name" needs the point of the write. A result that is the new name of a list is no
  reader of the old value for that write. For each later write it holds the same cells. A mark with no
  point let a later write of the old name pass (the generator's second family, seed 144).
- The evidence of a call is in the dispatch table at the call instruction. That of a reference is at the
  reference. The prototype read the callee's reference for both, so no call was checked.
- `[ x, …xs ]` is not a copy for the checker. `List.cons` answers the array that `xs` is a view of when
  the item is the element before the view. The exception is v2's rule 2: an item that its own instruction
  made.
- One module can move a speed figure of 32 roots. `bench/corpus/Ui/Html.beni` took 415 ms of 566 ms,
  because a run of atoms held each atom many times and `Frame.finish` compares runs in pairs. After the
  fix it takes 5 ms. Look at the time of each root, not only at the sum.
- A helper in a generated program's prelude that one checker refuses makes that checker refuse each
  program. Put a helper into a program only when the program names it.
- The time of this machine was one to two hours behind my estimate in the notes. Take each time from
  `date`.
