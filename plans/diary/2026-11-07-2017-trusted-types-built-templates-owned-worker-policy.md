## 2026-11-07 20:17 CET — Trusted Types: built templates and an owned worker policy first

**What I did**

- #2208, after the owner approved the phase-1 proposal: specified the
  `"trustedTypes"` key (`frontend.md` §10.1), interface 1.24 and
  `trusted_types_sink` (`boundary.md` §9.4.7), *Templates under Trusted Types*
  (`backend.md` §15.3), and the owned-policy-first rule with the withdrawal of
  `trust`/`scriptUrl` (`workers.md` §6, research §10, `workers-api.md` §1).
- Built it. With the key, `dom` reads its own template HTML back into the
  nodes the parser makes and hands `Rt.built` that data; `built` makes them by
  DOM calls and then runs `templateOf`'s steps. `raw`, `srcdoc` and `<script>`
  are refused at build time; `inline` refuses the key. `resolveScriptUrl`
  uses an owned policy before it looks at the default.
- Fixtures: `emit/dom/TrustedTypesTemplates`, `browser/dom/TrustedTypesShapes`,
  `build/bad/TrustedTypes{Raw,Srcdoc,Script}`, `browser/managed/PolicyMarkupPage`
  and `PolicyBesideForeignDefault`, and a devloop test for the key. Opened
  #2221 for a public `Browser.WorkerGlobal`.

**What I learned**

- A `<meta http-equiv="Content-Security-Policy">` inserted by script is
  enforced by Chrome from then on, `require-trusted-types-for` included. That
  is how a corpus page puts itself under Trusted Types without a header: the
  click arms the policy, and the templates made after it are the test. In
  Chrome the ordinary build of each new page throws `TypeError` at the click,
  and the owned-policy page gets `PolicyRefused` on master.
- With the key forced on for the whole `browser/` corpus, every `dom` page gave
  its golden except the three sinks and `SvgDrawing`, which gave its
  `.chrome-expected`: happy-dom's parser makes SVG elements inside a
  `<foreignObject>`; the builder, like Chrome's parser, makes HTML ones.
- A build without the key is byte-identical: `bench/size.mjs --pages-only`
  gave the same brotli bytes as master on every line. TodoMVC with the key is
  9 074 → 9 364 brotli in release.
- `foreign` is a keyword, so it cannot name a parameter in beni.
- The emit corpus reads a fixture's `beni.json` only when the fixture has a
  `platform/` directory, because only then is the fixture copied into a
  world of its own.
