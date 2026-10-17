# Actual compiler output, one shared example

`compile.mjs` compiles counter + doubled summary + controlled text input +
conditional validation with the pinned packages in this directory and the parent's
Solid compiler. The `.vue`, `.marko`, `.jsx` inputs and three output files are kept.
These are compiler outputs, not hand-written approximations of those frameworks.

- **Solid 2 rc.9:** clones a template once; captures node handles; inserts accessors
  and an effect for the controlled input; delegates events. The accessor read graph
  is dynamic. Copy the run-once component and stable local handles. The two measured
  ports use this actual compiler/runtime, including `For` and a projection selector.
- **Vue Vapor 3.6 rc.11:** creates cached templates, walks to node handles, attaches
  handlers, and emits `renderEffect` consumers and `createIf`. Copy direct DOM
  consumers and branch ownership; do not confuse Vapor with a VDOM renderer.
- **Marko 6.4.6 / compiler 5.42.12:** emits `$template`/`$walks`, numbered scope slots,
  `_let` setters and static consumer functions for text, controlled value and `if`.
  Copy compile-time consumer wiring and per-instance scopes. Resumability/server
  serialization is outside this study; there is no Marko byte benchmark here.

Sources: [Marko compiler API](https://markojs.com/docs/reference/compiler),
[Marko language](https://markojs.com/docs/reference/language),
[Marko's compilation model](https://markojs.com/docs/explanation/why-is-marko-fast),
[Vue compiler-vapor](https://github.com/vuejs/core/tree/main/packages/compiler-vapor),
[Solid source](https://github.com/solidjs/solid).

Run `npm ci --ignore-scripts` here, then `node compile.mjs`. Parent dependencies
must also be installed. These versions are intentionally pinned; the report does
not equate Solid 2's runtime floor with the old Solid 1.3.3 Conduit reference.
