## 2026-09-29 17:49 CEST — the markup lowering interface, and `ssr`: markup runs

**What I did**

- `src/markup/Interface.zig` (`beni_markup`, version 1.0): the typed tree, the `Lowering` value,
  and a `Context`/`Js` builder behind a table of functions over opaque handles, so a lowering
  imports nothing of the compiler and can spell no name it was not given. `build.zig` reads each
  platform's `"zig"`, makes `platform_<name>` modules, and generates the sorted registry with the
  compile-time version check; `-Dplatform=<dir>` and `beni.addPlatform` add one; the build id
  hashes platform Zig.
- The compiler side: `src/js/MarkupTree.zig` builds a module's tree from its `Bir`, the checker's
  markup section and the vocabulary's rows; `Lower` evaluates each root's values in order and
  places row values where the lowering asks; `Emit` checks the markup runtime against the union
  of exports, copies it when used, and writes program start data into the entry file.
- `node` names `ssr` (`platforms/node/zig/ssr.zig`, `markup.js`); `html`'s Zig is the parser table.
  Eleven `run/` fixtures (text, attributes, class/style, holes, `For`, nested rows, `Show`,
  components, blocks, field identity over a test platform's `refEq`, a hoist-name collision),
  emit goldens, seven `build/bad` fixtures, determinism, warm-vs-cold and format round-trip
  scenarios, and a toy external platform built into a second beni inside `test-blackbox`.

**What I learned**

- Importing `Html` from `Node` cost every `node` build about 350 million instructions — the
  vocabulary module is checked by every build that imports it — and pushed a cache test over the
  budget. `render` lives in its own module, `Ssr`, so only programs that render markup pay.
- A lowering that must keep no state still needs to find what `module` hoisted, and needs memory
  to build lists: `cx.hoisted` and `cx.arena` were the two smallest answers.
- `Maybe`'s padded payload makes `Just ()` and `Nothing` both have a `null` payload; `cx.maybe`
  alone cannot tell them apart, so `cx.isJust` exists.
- A kind named `<Module>$k<inst>` collides with a declaration named `k<inst>`; hoist names skip
  declared names.
