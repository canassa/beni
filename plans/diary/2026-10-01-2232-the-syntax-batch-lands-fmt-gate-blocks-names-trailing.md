## 2026-10-01 22:32 CEST — The syntax batch lands: fmt gate, λ, blocks, names, trailing lambdas

**What I did** (as manager; Opus agents in worktrees implemented every slice)
- Merged the repo-wide reformat and the `beni-fmt-check` gate, then fixed the gate walking
  gitignored bench output (`bench/arrays/dist` and others), which my merge script had pushed red.
- Landed `λ` as the only lambda head (`backslash_lambda_removed`, `--migrate-lambda`), blocks in
  place of `let … in` (`statement_not_unit`, `block_ends_in_binding`, `let_removed`), `Int.mod`,
  `Int.rem`, `Float.log` with `name_removed`, `Debug.log` label first, the call-style hints and
  `suspicious_argument_order`, and trailing lambdas as `fmt`'s own rule. Every mechanical
  migration was its own commit and left emitted JavaScript byte-identical.
- Y10 hit a wall (moving `Int`/`Float` out of `Basics` makes an import cycle); the agent stopped,
  the owner chose plain `Int`/`Float` modules beside the types in `Basics` (S9).
- The owner adopted Lean-style Unicode notation (S8: → ← ≠ ≤ ≥ ▷ ◁ … ×); slice 17 specified it
  (`language.md` §12.7–§12.9, `frontend.md` §11.8) with Z1–Z15 awaiting the owner.
- Merged the schema-engine gap work: release builds keep top-level `const` (V8 folds it; a `let`
  made a hot call 2.5× slower), and schema callbacks cross to the host at a type variable so
  field renaming applies. A cold-path rewrite of `core/Schema.beni` awaits the owner.

**What I learned**
- A merge script must stop on a red gate before `git push`; chaining with `;` pushed a failure.
- `reduce` in V8 is as fast as a loop only once TurboFan compiles its caller; in Maglev it is
  10–20× slower, because the builtin's loop cannot be on-stack-replaced. Compiling folds to
  plain loops is the right shape.
- Columns counted in bytes misplace carets and the 100-column limit after every non-ASCII
  symbol; the Unicode notation makes code-point columns necessary (Z4).
