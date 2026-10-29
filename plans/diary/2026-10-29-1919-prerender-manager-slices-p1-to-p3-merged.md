## 2026-10-29 19:19 CET — Prerender manager: slices P1 to P3 merged

### What I did

- Managed the prerender work (`docs/design/prerender.md`, #1160) as planner and validator.
  Implementer agents each opened one PR and ran one adversarial reviewer. I checked each file
  list, CI, that programs which do not prerender build byte for byte as on `master`, and spot
  checks that new fixtures fail before the fix. Then I merged each PR with a rebase.
- Merged: P1, the string form and one page (Node on `PATH`, `findOnPath`); P2a, hydration
  (`Inline.take`, every tag checked in release after #1186); routing on `browser-inline`; and
  P3, routes (#1203: `Browser.prerender`, `"build"."origin"`, a page per route, `{{title}}`,
  `beni serve` prerendering every rebuild, lowering interface 1.22).
- Corrected my misreading of the engine decision. Prerendering runs under Node, not an embedded
  engine. I closed #1177 and its PR, and PR #1185 amended the doc.
- Gave every agent the owner's rules from 2026-10-29: Debug self-hosted builds, targeted tests
  while developing, the full gates once before the push, report slow steps, no `/tmp`, clean up
  afterwards.

### What I learned

- When the owner says "go with the recommendation" and my own leaning differs from the
  document's, ask which one before writing a decision down. A misread decision fanned out into
  two lanes of work that were thrown away.
- Keep an implementer's worktree until its PR merges. I removed P1's worktree early, and a CI
  fix then needed a new agent.
- Zig's process spawn falls back to a default `PATH` when `PATH` is unset. A "no node" test
  passed on NixOS and failed on Ubuntu until the build searched `PATH` itself.
- An agent that removes its own worktree cannot run further commands. The manager finishes the
  branch and scratch cleanup from the main checkout.
- Open after P3: P2b (input before the takeover, §6.5), P4 (build-time data, to be specified
  first), and the debt issues #1164, #1166, #1168, #1169, #1170, #1176 and #1202.
