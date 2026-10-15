## 2026-10-03 16:35 CEST — A design pass with the owner, Zig 0.17, and the build id

**What I did** (as manager; three Sonnet research agents and two Opus implementers in worktrees)
- Put the open decisions to the owner one at a time and recorded each in the spec: the package
  model (URL + hash, enforced semver, one version per package, path dependencies for apps only;
  `fast-compiler.md` §3.1); interop (ports withdrawn, one platform per project, libraries pure beni;
  `boundary.md` §3.1); the daemon's D6–D10 after research 53; chunking (static multi-entry, `lazy`
  as a call that may suspend with a typed `LoadError`, preload; `backend.md` §10); all ~39 markup
  decisions (MD1 components may name their own module, MD2 optional props are omittable `Maybe`
  fields, defaults written `¿` in a record pattern and as an expression after research 54, MD10 and
  MD37 element spread, run-time tags, portals and `ref` to be supported, MD12 handlers call
  `preventDefault` themselves); `sync` writable by every package.
- Merged the Zig 0.17 port's last fix (a nondeterministic allocation-failure test) after the agent
  could not reproduce the reported memory exhaustion; merged the build id as a build step, so
  one-shot builds and plain `--watch` always carry the right id. The owner parked incremental
  compilation (`plans/build-speed.md`).

**What I learned**
- Research agents overstate: two of four spot-checks in research 53/54 needed correcting (Rust
  Glancer's author; Roc #6423 "not planned", not a withdrawal). Check the claims a decision rests on.
- The owner wants decisions discussed in prose, one at a time, with plain explanations and a
  recommendation — not multiple-choice prompts, and not jargon ("props" needed explaining).
- Under `-fincremental --watch`, Zig 0.17 never re-sends a compiler its command line, so every
  generated module — the core pack included — silently stays the first build's.
