# Solid 2's JSX compiler, and how beni ports it

**Status:** research, 2026-09-29. Not normative. It feeds the specification slices that
[`plans/browser-decisions.md`](../../plans/browser-decisions.md)'s answers W25–W34 call for. It
takes those answers as given: The Elm Architecture (W25); compiled templates ported from
dom-expressions' Rust compiler, where `view` re-runs and holes compare by reference, never with
signals (W26); untouched fields keep their identity and there is no `lazy` (W27); Solid 2's render
loop (W28); and Solid 2's answers on W29–W34.

**Question.** What does the compiler emit, how is it built, what changes when `view` re-runs
instead of signals firing, where does each piece land in beni's pipeline, how can a platform plug a
target in without writing compiler code, and what would the port cost?

**Citation convention.** `c/…` is `references/dom-expressions/packages/compiler/src/…`, `rt/…` is
`references/dom-expressions/packages/runtime/src/…`, `solid/…` is `references/solid/…`. Every
claim about the Rust source carries a `file:line`. Every output block below was produced by the
compiler itself, built from the vendored source (§1).

---

## 0. Findings

1. **Most of the compiler is about signals, and the part beni needs is small and separable.**
   The crate is 24 697 lines of Rust: `dom/` 4 431, `shared/` 7 717, `ssr/` 3 392, `universal/` 2 100,
   `refresh/` 3 465, `directives/` 2 307 (`wc -l`). The client DOM path is `dom/` plus about half of
   `shared/`. Of that, the reactive wrapping, hydration, Babel output parity and OXC plumbing do
   not transfer. What remains to port is **template extraction, the sibling walk, the
   attribute/property/event write rules and the slot markers**, roughly 3 000 lines of Rust in
   `dom/element.rs`, `dom/children.rs`, `dom/template.rs`, `dom/attrs.rs`, `dom/set_attr.rs`,
   `dom/events.rs` and `dom/dynamics.rs`.
2. **Every signal assumption in the output lives in five places, and each has a TEA
   replacement.** Those places are grouped `effect(compute, commit)` per template root
   (`c/dom/dynamics.rs:27-192`), `insert(parent, () => expr)` thunks
   (`c/dom/children.rs:300-346`), `memo` around conditionals (`c/shared/condition.rs:137-200`),
   `createComponent` with prop getters (`c/shared/component.rs:46-180`) and `ref`
   (`c/dom/attrs.rs:354-451`). The commit half of the grouped effect, `v !== _p$?.v && write`
   (`c/dom/dynamics.rs:150-179`), is exactly the P2 per-hole check. beni keeps that half and
   replaces the compute half with a compiled `patch(instance, values)` function.
3. **W29 already has an answer in Solid's own split, and it is measured.** Solid puts native
   children into the parent's template and turns only components and dynamic expressions into
   `insert` holes (`c/dom/children.rs:147-223`). Ported to TEA, a JSX root compiles to a *template
   kind* with a compiled mount and patch. A root whose value escapes into a helper, a `let`, a
   `case` branch or a list evaluates to a small **block** `{t, v}` that the hole patches when `t`
   matches and remounts when it does not. When the consumer is visible (the root of `view`, a
   `For` row, a component call, inline JSX), the block is compiled away into direct calls: that is
   P2. The block shape is blockdom's, and R29 measured blockdom ahead of Solid 2 on **all nine**
   script medians (R29 §5.4: `select` 1.71 against 2.60 ms, `update 10th` 1.47 against 2.35). So
   **the fallback beats the bar, and the fast path is P2.**
4. **I built a runtime and ran it.** It is 259 lines of JavaScript: templates, delegated events,
   typed child slots, a positional list, a keyed list over dom-expressions' `reconcileArrays`
   without `$$SLOT`, a microtask render loop with a synchronous `flush`, and the SSR string
   helpers. The client part is **3 612 bytes minified and 1 482 brotli**. Driving a hand-emitted
   benchmark app through it passes create, update-every-10th (the same nodes stay), select by a
   delegated click and a microtask flush, swap (the same nodes move), remove, append and clear, plus
   a page with helper blocks, a branch swap and a positional list (§4.7). The whole app with
   `update` is **2 201 brotli**; Solid 2's is **22 163** (R29 §12.1).
5. **Solid 2 has no `Index`.** `solid/packages/solid/src/index.ts:269` lists
   `Index, // handled by For`, and `keyed={false}` replaces it
   (`solid/documentation/solid-2.0/03-control-flow.md:23,50`). W33's "`For`/`Index`" is therefore
   Solid 2's `For` with three keying modes, plus `Repeat`. **One of those modes misbehaves in an
   immutable language.** Keying by reference (Solid's default) remounts every row whose record
   changed, because an updated row is a new object. `update every 10th` would rebuild 100 rows
   instead of patching them. beni should steer people to `key={…}` (§4.4).
6. **dom-expressions ships a dormant "patch mode" in exactly the TEA shape, and upstream has since
   deleted it.** `_$patchDriver(subject, (_n$, _p$, _f$) => { const v = e(_n$); if (_f$ || v !==
   e(_p$)) write })` (`c/dom/dynamics.rs:194-301`, `c/shared/patch.rs:1-10`) is a compiled patch
   over new and previous inputs. It is off by default (`c/compiler.rs:297-304`), and the newer tree
   in `references/solid` removes it (`solid/.changeset/remove-patch-channel.md`). Treat it as prior
   art for the shape, not code to port.
7. **The compiler knows HTML, and `boundary.md` §5 says beni's may not.** It has built-in tables for
   delegated events, void elements, closing-tag omission, SVG and MathML, stateful properties and
   namespaces (`c/shared/constants.rs:7-285`), and it links `html5ever` to reject markup the
   browser would restructure (`c/shared/validate.rs:1-23`). §5 below splits these into
   **vocabulary**, which a platform declares, and **the HTML parser's own rules**, which belong to
   the `dom` lowering target the way JavaScript's reserved words belong to the emitter. Where that
   line falls is the owner's call (Q2).
8. **A platform can plug in without extending the compiler.** dom-expressions already works this
   way: one front end and one classification authority serve three targets
   (`c/shared/transform.rs:12-80`, `c/shared/classify.rs:1-11`). Each target imports its runtime
   from a configurable module name (`c/dom/template.rs:533-545`). `universal` is a renderer
   interface of twelve host operations that knows no element names at all
   (`rt/universal.js:14-27`). beni's version: the compiler owns a fixed set of targets (`dom` and
   `ssr` first). A platform selects one in its manifest and supplies a vocabulary module and a
   runtime sibling of well-known exports, checked the way `boundary.md` §4 checks siblings. The
   `foreign` wall does not move (§5.6).
9. **Four collisions with documents and plans.** (a) `plans/browser-platform.md` names
   "`backend.md` new §11", but §11 is *Source maps* (`backend.md:2841`); rule 2 means the new
   section has to be §15. (b) That plan's L1 (quoted text, desugaring to calls), R1 (a
   `--release`-gated recogniser) and R2 (`Keyed msg`) predate W30, W32 and W33 and are superseded.
   (c) `delegateEvents([...])` is a top-level call with an effect (`c/dom/template.rs:267-269`),
   which `backend.md` §9's purity premise forbids. Event names have to be registered at program
   start. (d) Templates dedupe on markup (`c/dom/template.rs:284-289`), but a TEA block's identity
   must be its *source site*, or two branches with equal markup would patch into each other (§4.5).

---

## 1. Method

- **Sources, pinned.** `references/dom-expressions` at `e97e429` (2026-08-24) is the tree the
  owner named. `references/solid` at `be46a04` (2026-09-19) vendors a later copy of the same
  compiler, 35 088 lines with TSRX added and `shared/patch.rs` gone. R27 cites that later copy, so
  a few spellings differ: `_$$click` there against `$$click` here (`c/dom/events.rs:45`,
  `solid/packages/compiler/src/dom/events.rs:45`).
- **Built and run.** The vendored crate was copied to the scratchpad and built with
  `nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc -c cargo build --release
  --no-default-features`, using rustc 1.98.1 and nothing installed system-wide. The build takes
  38 s. A 20-line example binary calls the public `compile()` (`c/lib.rs:34`, `c/compiler.rs:117`).
  Fourteen inputs, one per JSX shape, were compiled under `dom`, `dom` without wrappers, `ssr`,
  `ssr` hydratable, `dom` hydratable and `universal`.
- **Runtime experiment.** A hand-written runtime and a hand-emitted app, driven through `linkedom`
  under Node 24, with sizes measured by `esbuild --minify` and `brotli -q 11` (§4.7). Both are in the
  scratchpad (§10).
- **Read, not run:** the runtime `rt/client.js` (2 010 lines), `rt/universal.js` (366),
  `rt/server.js` (4 197), `rt/reconcile.js` (158), Solid's `flow.ts`, and the fixture corpora under
  `packages/compiler/__tests__/fixtures/` and `packages/babel-plugin-jsx/test/`.

---

## 2. What it emits

Defaults throughout: `generate: "dom"`, `delegateEvents: true`, `effectWrapper: "effect"`,
`memoWrapper: "memo"`, `omitLastClosingTag: true`, quotes omitted where legal
(`c/compiler.rs:75-104`). All runtime imports come from `moduleName`
(`c/dom/template.rs:136-242`).

### 2.1 A static element

```jsx
const v = <div class="a" id="x"><span>hi</span><br/><p>there <b>you</b></p></div>;
```
```js
var _tmpl$ = /* @__PURE__ */ _$template(`<div class=a id=x><span>hi</span><br><p>there <b>you`);
const v = _tmpl$();
```
One template, one clone, no other runtime call. Closing tags that the parser would reconstruct are
omitted (`c/dom/attrs.rs:510-563`, with the tables at `c/shared/constants.rs:39-91`). Quotes are
dropped where HTML allows it (`c/shared/utils.rs:271-290`). `template()` builds the prototype
lazily on the first call and clones it after that (`rt/client.js:140-158`).

### 2.2 Attribute holes, all on one element root

```jsx
<div id={props.id} class={props.cls} title={title} style={{color: props.color, "font-size": "12px"}}
     disabled={props.off} data-k={props.k} aria-label="static">
  <input value={props.value} checked={props.on} /></div>
```
```js
var _tmpl$ = _$template(`<div aria-label=static style=font-size:12px><input>`);
  var _el$ = _tmpl$(); var _el$2 = _el$.firstChild;
  _$setAttribute(_el$, "title", title);                 // identifier: static, written once
  _$effect(() => ({ e: props.id, t: props.cls, a: props.color, o: props.off, i: props.k,
                    n: props.value, s: props.on }),
    ({ e, t, a, o, i, n, s }, _p$) => {
      e !== _p$?.e && _$setAttribute(_el$, "id", e);
      _$className(_el$, t, _p$?.t);                     // class/style: the helper diffs
      a !== _p$?.a && _$setStyleProperty(_el$, "color", a);
      o !== _p$?.o && _$setAttribute(_el$, "disabled", o);
      i !== _p$?.i && _$setAttribute(_el$, "data-k", i);
      _el$2.value = n ?? "";                            // stateful property: no guard
      _el$2.checked = s; });
```
- Every dynamic binding under one template root shares **one** effect. The compute half builds an
  object and the commit half destructures it (`c/dom/dynamics.rs:82-192`). A root with exactly
  one binding gets a two-argument effect instead (`:36-80`).
- The guard is `v !== _p$?.v` (`:150-179`). `textContent` uses `!_p$ || v !== _p$.v` (`:126-149`).
  `class`, `style` and the stateful properties get no guard, because the helper diffs or the DOM
  owns the value (`:106-124`, `c/shared/constants.rs:219-247`).
- Static and "confident" values are inlined into the template. The static half of `style` is
  split out at compile time (`c/dom/attrs.rs:197-257`, `c/shared/attr_plan.rs:327`).
- An attribute is **dynamic by syntax alone**: any call, member access, spread or `in` counts
  (`c/shared/classify.rs:166-265`). A bare identifier is static, which is why `title` above is
  written once.
- What each write compiles to is decided in one function, `set_attr_expression`
  (`c/dom/set_attr.rs:25-228`). `style:` properties go to `setStyleProperty` (`:53-75`), `class`
  object keys become `classList.toggle` (`:77-98`), `style` and `class` go to their helpers
  (`:100-116`), and a dynamic `textContent` writes `.data` (`:118-133`). Child properties,
  `prop:` and stateful properties become assignments, with the `<select value>` microtask
  workaround (`:135-192`). A namespace prefix becomes `setAttributeNS` (`:194-209`). Everything
  else becomes `setAttribute` (`:211-222`). **The default is an attribute, not a property.**

With `effectWrapper: false` the effect disappears and the same writes run once, in order
(`out-dom-wrapperless.txt`). That form is the mount half of a TEA template.

### 2.3 Text holes

```jsx
<p>Hello {props.name}, you have {count()} items and {n} more.</p>
```
```js
var _tmpl$ = _$template(`<p>Hello <!>, you have <!> items and <!> more.`);
  _$insert(_el$, () => props.name, _el$3);   // member access: thunk
  _$insert(_el$, count, _el$5);              // `count()` unwraps to the getter
  _$insert(_el$, n, _el$7);                  // identifier: by value, no effect
```
The `<!>` placeholder keeps adjacent template text nodes from merging when the page is parsed
(`c/dom/children.rs:257-281`, `:557-634`, `:701-719`). A parent with two or more dynamic slots
gives each slot its own marker, because a marker also serves as the `$$SLOT` ownership tag
(`c/dom/children.rs:64-70`). A literal expression folds into the template text: `{"lit"} {1+2}`
becomes `<p>lit 3` (`c/dom/children.rs:230-254`). Text is trimmed with Babel's algorithm,
`trim_jsx_text` (`c/shared/utils.rs:210-242`).

### 2.4 Children expressions and conditionals

```jsx
<ul><li>first</li>{props.items}<li>mid</li>{cond() ? <b>y</b> : "n"}{props.a && <i>a</i>}<li>last</li></ul>
```
```js
  _$insert(_el$, () => props.items, _el$2.nextSibling);
  _$insert(_el$, (() => { var _c$ = _$memo(() => !!cond());
                          return () => _c$() ? _tmpl$2() : "n"; })(), _el$4);
```
A ternary or `&&` in a hole memoises its test, so the branch is rebuilt only when the test's
truthiness changes (`c/dom/condition.rs:71-84`, `c/shared/condition.rs:137-200`). Nested JSX
inside a hole stays raw until a deferred pass lowers it after the parent's template has registered
(`c/shared/transform.rs:447-530`).

### 2.5 Components

```jsx
<Child a={1} b={props.b} c={() => props.c} d={x} {...props.rest}><span>{props.kid}</span></Child>
```
```js
_$insert(_el$, _$createComponent(Child, _$mergeProps(
  { a: 1, get b() { return props.b; }, c: () => props.c, d: x },
  () => props.rest,
  { get children() { var _el$2 = _tmpl$(); _$insert(_el$2, () => props.kid); return _el$2; } })), _el$3);
```
A capital initial, `_`, `$`, a member expression or `this` means a component
(`c/shared/utils.rs:36-49`). Props that classify as dynamic become getters
(`c/shared/component.rs:183-198`, `:118-140`). `children` is a getter so the subtree is built only
if the callee reads it (`:154-167`). A spread becomes a `mergeProps` source (`:61-67`).

### 2.6 Spread on an element

```js
_$spread(_el$, _$mergeProps({ class: "s" }, () => props.attrs, { get id() { return props.id; } }), true);
```
From here on the element's attributes are handled entirely at run time
(`c/dom/attrs.rs:106-148`, `rt/client.js:424-446`). R27 §6.11 D measures this at about 4 900 brotli
bytes of runtime.

### 2.7 Events

```js
_el$2.$$click = onClick;                          // identifier bound to a function: delegated, one write
_$addEvent(_el$3, "click", props.onClick, true);  // not provably a function: runtime helper
_el$4.$$click = () => send(1);
_el$5.$$input = (e) => set(e.target.value);
_$addEvent(_el$6, "scroll", h);                   // not in the delegated set: native listener
_el$7.$$click = handler; _el$7.$$clickData = 7;   // [handler, data] form
_$delegateEvents(["click", "input"]);             // top level, once per module
```
Delegation applies to a fixed list of 22 event names (`c/shared/constants.rs:11-37`), extensible
by option (`c/dom/events.rs:110-117`). A handler known to be a function is one property write
(`c/dom/events.rs:60-66`, predicate `:192-200`). Anything else goes through `addEvent`
(`:69-75`). Non-delegated events use `addEventListener` (`:103-107`). At run time one listener per
event name walks up from the target and calls `node.$$click`, passing data when there is some
(`rt/client.js:1695-1797`).

### 2.8 Refs

```js
var _ref$ = el;
typeof _ref$ === "function" || Array.isArray(_ref$) ? _$ref(() => _ref$, _el$) : el = _el$;
```
A ref either assigns the element to a variable or calls a function with it
(`c/dom/attrs.rs:354-451`, `rt/client.js:459-472`).

### 2.9 `For`, `Show` and friends

```js
_$insert(_el$2, _$createComponent(For, { get each() { return props.rows; },
  children: (row) => (() => { var _el$6 = _tmpl$3(); /* walks */
     _$insert(_el$7, () => row.id); _el$9.$$click = () => select(row.id);
     _$insert(_el$9, () => row.label);
     _$effect(() => row.id === props.sel ? "danger" : "", (_v$, _$p) => _$className(_el$6, _v$, _$p));
     return _el$6; })() }));
_$insert(_el$, _$createComponent(Show, { get when() { return props.ok; },
  get fallback() { return _tmpl$4(); }, get children() { return _tmpl$(); } }), _el$4);
```
**The compiler knows nothing about `For` or `Show`.** They are ordinary components. The
`builtIns` option only rewrites where they are imported from (`c/shared/component.rs:224-235`).
The row callback is compiled like any other function that returns JSX. In Solid 2, `For` is
`mapArray` behind a lazily created accessor (`solid/packages/solid/src/client/flow.ts:81-109`).
The DOM diff is `reconcileArrays`, which is udomdiff (`rt/reconcile.js`).

### 2.10 Fragments

```js
const a = [_tmpl$(), (() => { var _el$2 = _tmpl$2(); _$insert(_el$2, x); return _el$2; })()];
const b = ["text ", _$memo(y)];
```
A fragment is an array (`c/shared/fragment.rs:14-79`), and `insert` treats an array as a run of
nodes (`rt/client.js:1852-1863`).

### 2.11 SVG and namespaces

```js
var _tmpl$ = _$template(`<svg viewBox="0 0 10 10"><circle cy=5 r=4 xlink:href=#a></circle><foreignObject><div>`);
var _tmpl$2 = _$template(`<svg><path></svg>`, 2);   // an SVG element at the template root
```
An SVG or MathML element that is not itself `<svg>` or `<math>` gets wrapped in its owner tag at
the template root, and the template is flagged `2`, which unwraps it on clone
(`c/dom/element.rs:476-495`, `:394-405`; `rt/client.js:140-148`). Custom elements and lazy
`img`/`iframe` subtrees use `importNode` (flag `1`, `c/dom/element.rs:497-521`). A namespaced
attribute resolves through `namespaces` (`c/shared/constants.rs:249-257`). Only `prop:` survives as
a reserved prefix (`:259-265`).

### 2.12 The other two targets, for the same row

- **`ssr`** turns the template into an array of strings, calls components directly, drops events
  and refs, and escapes values at run time:
  ```js
  var _tmpl$ = ['<tr class="', '"><td class="col-md-1">', '</td><td class="col-md-4"><a>', "</a></td>…</tr>"];
  const Row = (props) => { var _v$ = () => _$ssrClassName(props.selected ? "danger" : ""), … ;
                           return _$ssr(_tmpl$, _v$, _v$2, _v$3); };
  ```
  Events are dropped at `c/ssr/transform.rs:1754-1760`, refs at `:1741-1752`. `ssr()` returns
  `{ t }` so that `escape()` knows not to escape it again (`rt/server.js:2590-2601`, `:3209`).
- **`universal`** has no template string. It emits a `createElement` chain and passes events
  through as ordinary props:
  ```js
  var _el$4 = _$createElement("a", { onClick: () => props.select(props.row.id) });
  _$insertNode(_el$3, _el$4); _$insert(_el$4, () => props.row.label);
  _$effect(() => props.selected ? "danger" : "", (_v$, _$p) => _$setProp(_el$, "class", _v$, _$p));
  ```
  The lowering is `c/universal/transform.rs:426-520`. Full listings for every input are in
  `out-*.txt` (§10).

---

## 3. Architecture

### 3.1 Passes

1. **Parse** with OXC, with parentheses discarded so the matchers see Babel's tree
   (`c/compiler.rs:136-152`).
2. **One visitor spine.** The `JsxTransform` trait (`c/shared/transform.rs:12-80`) is implemented
   by all three targets (`:641`, `:726`, `:810`). `visit_expression` replaces each JSX root in place
   (`:401-440`). JSX left inside attribute values and holes is lowered later by a deferred walk
   (`:447-530`).
3. **Per root:** `lower_element_with_setup` (`c/dom/element.rs:226-446`). It opens a template
   string, plans and lowers the attributes, which either go into the string or become operations
   and dynamic slots (`:284-306`). It lowers the children recursively into the same string
   (`:329-350`), then wraps the dynamic slots (`:351-387`) and registers the template (`:412-416`).
   The output is `var _el$ = _tmplN()`, then every walk declaration, then the operations
   (`:420-446`). Walks come first "so walks are resolved before inserts mutate sibling positions"
   (`:429-431`). A root with setup becomes an arrow IIFE (`:213-224`), except in statement
   position, where the setup is inlined (`c/shared/statements.rs`).
4. **Module epilogue.** Imports are added for exactly the helpers that were used
   (`c/dom/template.rs:16-51`, `:136-242`). Every template is checked with `validate`
   (`:248-261`). Template declarations are hoisted as `/* @__PURE__ */` (`:262-264`, `:547-564`).
   One `delegateEvents` call goes at the end (`:267-269`).

### 3.2 Data structures

The compiler rewrites OXC's AST in place and has no IR of its own. Per root it keeps a
`TemplateHtml` holding the emitted markup plus a closed-tag, attribute-free copy for `validate`
(`c/dom/template.rs:64-89`). It keeps three statement lists, declarations, operations and
`DynamicSlot { elem, key, value, tag_name, … }` (`c/dom/dynamics.rs:13-21`), and a per-module
`DomTemplateState` holding the template list, one "uses" flag per helper and the delegated event
set (`c/dom/template.rs:16-62`). Names are numbered: `_el$N`, `_tmpl$N`, and `get_numbered_id`
for effect keys (`c/shared/utils.rs:411-495`, `c/dom/ids.rs`). A `BindingTable` records scopes so
that `is_function` and `is_const` can drive the event and ref fast paths
(`c/shared/bindings.rs:178-240`).

### 3.3 Template extraction and hole paths

- **Static subtrees are inlined whole.** `lower_static_native_template` returns `None` as soon as
  anything in the subtree needs a runtime operation (`c/dom/static_template.rs:11-60`).
- **Holes are located by code, not by an encoded path.** `child_walk_expression` chains
  `.nextSibling` from the most recently declared walk variable, or from a hydration anchor, and
  starts again from `parent.firstChild` for each new parent (`c/dom/template.rs:413-458`). A walk
  variable exists only where something needs one, a rule ported from Babel's `detectExpressions`
  (`c/dom/children.rs:427-535`). There is therefore no overflow case like Dioxus's `u128` path
  (R28 §8.1), and nothing to put in a specification about it.
- **Slot markers:** the next static sibling if there is one; a dedicated `<!>` when the slot sits
  between two text runs or its parent has several slots; `null` when the slot is the parent's only
  meaningful child (`c/dom/children.rs:557-634`). Hydration instead uses a `<!$><!/>` pair
  (`:636-681`).
- **Templates dedupe on markup within a module.** The first registration's flag wins
  (`c/dom/template.rs:276-304`).

### 3.4 What the compiler has to know, and where it lives

Everything is hard-coded in Rust. There is no data file.

| Knowledge | Where | Kind (§5.4) |
|---|---|---|
| component or element: a capital initial, `_`, `$`, a member expression | `c/shared/utils.rs:36-49` | language rule (W31) |
| void elements | `c/shared/constants.rs:267-285` | HTML parser |
| closing-tag omission: always-close, block and inline lists | `c/shared/constants.rs:39-91`, `c/dom/attrs.rs:510-563` | HTML parser (an optimisation) |
| SVG and MathML element names | `c/shared/constants.rs:95-217` | vocabulary (a namespace per element) |
| delegated event names | `c/shared/constants.rs:11-37` | vocabulary |
| child properties: `innerHTML`, `textContent`, `innerText` | `c/shared/constants.rs:7-9` | vocabulary |
| stateful properties such as `input.value` and `checked` | `c/shared/constants.rs:219-247` | vocabulary |
| attribute namespaces such as `xlink:` | `c/shared/constants.rs:249-257` | vocabulary |
| markup the browser would restructure: `html5ever` round-trip | `c/shared/validate.rs:1-23`, `c/dom/template.rs:248-261` | HTML parser |
| claimed elements (`a[href]`, `form[action]`) | `c/dom/element.rs:547-577` | a router hook; not needed |

### 3.5 Configuration

`CompileOptions` (`c/compiler.rs:47-73`) has these fields:

- `generate`: `dom`, `ssr`, `universal`, or `dynamic`, which is universal routing named elements to
  DOM.
- `module_name`, where the runtime is imported from.
- `hydratable`, `delegate_events` and `delegated_events`.
- `effect_wrapper` and `memo_wrapper`, which can be switched off (`c/config.rs:28-39`).
- `wrap_conditionals`, `inline_styles`, `omit_*` and `validate`.
- `built_ins`, the components imported from the runtime.
- `renderers`, which routes elements by name list to a renderer module (`c/compiler.rs:180-197`,
  `c/dom/element.rs:197-211`).
- `patch_driver`, which is dormant (`:297-304`).

The option matrix is tested (`__tests__/option-matrix.test.js`).

### 3.6 What `dom`, `ssr` and `universal` share

- **One classification authority:** "Nothing outside this module may re-derive dynamic
  classification" (`c/shared/classify.rs:1-11`). A trace recorder lets the tests assert that
  every target makes the same decisions (`:283-291`). A cross-mode suite compiles the union of all
  fixtures through every mode (`__tests__/cross-mode-parity.test.js:1-10`).
- **Shared lowerings with per-target seams:**
  - components through `ComponentLower` (`c/shared/component.rs:1-3`; implemented for dom at
    `:200`, universal at `c/universal/transform.rs:1841`; ssr uses its own
    `c/ssr/transform.rs:848`);
  - component children (`c/shared/component_children.rs:1-4`);
  - fragments (`c/shared/fragment.rs:1-3`);
  - conditions through `ConditionBuilder` (`c/shared/condition.rs:1-4`);
  - the `ModeLower` trait, which covers "how an element lowers and how a dynamic child thunk is
    wrapped" (`c/shared/mode_lower.rs:20-39`);
  - attribute planning in `AttrPlanner`, used by all three (`c/ssr/transform.rs:18`, `:428`;
    `c/universal/transform.rs:355`).
- **Per target:** the element lowering and the helper vocabulary it emits: `dom/`,
  `ssr/transform.rs` and `universal/transform.rs`.

### 3.7 How much of it beni needs

For the client DOM target, beni needs `dom/element.rs`, `children.rs`, `template.rs`, `attrs.rs`,
`set_attr.rs`, `events.rs`, `static_template.rs` and the commit half of `dynamics.rs`, plus
`shared/utils.rs`'s text and escaping rules and parts of `attr_plan.rs`. That is about 3 000 lines
of Rust.

What beni does **not** need:

- hydration, which has 66 mentions in `dom/`;
- Babel parity (229 comments cite Babel);
- `this` capture and OXC plumbing: `shared/transform.rs`, `ast.rs`, `ast_builder.rs`,
  `statements.rs`, `bindings.rs`, about 3 500 lines, replaced by beni's own resolver and `JsIr`;
- the reactive wrappers;
- `spread`;
- `refresh/` (hot reload), `directives/` and `lazy.rs`.

The Zig will be smaller than the Rust: beni's types answer, exactly, what `classify.rs` guesses.

---

## 4. The adaptation to TEA

### 4.1 Where the output assumes signals

| Construct | Emitted by | Why it exists | TEA replacement |
|---|---|---|---|
| grouped `effect(compute, commit)` with `_p$` | `c/dom/dynamics.rs:27-192` | re-run when a signal changes | the template's compiled `patch(inst, v)`. Last values live in instance fields and the commit statements stay the same (`v !== inst.h && write`) |
| `insert(parent, () => e, marker)` | `c/dom/children.rs:292-346`, `c/dom/condition.rs:71-84` | subscribe the hole | `child(parent, marker, slot, v)`, **specialised by the checker's hole type**: a `String` hole becomes a guarded `.data =` and loses `insert`'s 13 checks (R27 §6.7, §6.11 A) |
| `memo(() => !!cond)` | `c/shared/condition.rs:137-200` | avoid rebuilding a branch while the test's truthiness holds | none needed. A branch is a block and `t === t` is the test (§4.5) |
| `createComponent` + getters + `mergeProps` | `c/shared/component.rs:46-180` | the component runs once and reads its props lazily | call the component's compiled pair with a plain props record. **Skip it when every prop is `===`** (§4.3) |
| `get children()` | `c/shared/component.rs:154-167` | laziness | children are values: blocks, or compiled inline |
| `ref` | `c/dom/attrs.rs:354-451` | a mutable variable | not ported (Q6) |
| `spread`, `mergeProps` | `c/dom/spread.rs`, `rt/client.js:424-446` | unknown key set | not ported (R27 §6.11 D) |
| `rowProof`, `patchDriver` | `c/dom/element.rs:711-834` | dormant, and removed upstream | not ported. Its shape is prior art |

### 4.2 The emitted shape: template kinds, instances and blocks

A JSX root at a source site `s` compiles to a **template kind** `T_s = { m(v) → inst, p(inst, v) }`.

- `v` holds the root's hole values, in source order.
- `m` clones `T_s`'s template, runs the walks (§3.3, unchanged) and writes every hole. It is the
  Solid output with the wrappers off (§2.2).
- `p` holds one guarded write per hole, which is Solid's commit half, with last values in instance
  fields instead of `_p$`.

**The fast path: a consumer the compiler can see.** Nothing is allocated, and the parent's `m`
and `p` call the child's directly. There are four such consumers:

- the root of `view`, which the platform's program calls;
- a `For` row lambda, compiled to `row$m(item, env)` and `row$p(inst, item, env)`, where `env`
  holds the lambda's free variables other than the item;
- a component call (§4.3);
- inline JSX or `if`/`case` in a hole.

That is P2 exactly. §4.7 has the emitted rows.

**The general case: a root whose value escapes.** A helper result, a `let`, a list element or a
record field evaluates to `block(T_s, [v…])`. The slot receiving it patches when `t` matches and
remounts when it does not. This is Solid's `insert` stripped of reactivity. It is also
blockdom's model, which R29 measured ahead of Solid 2 on every operation (§0 item 3). This answers
W29's cases (`{viewStatus model}`, `List.map … viewHit`, `let banner = …`, recursion) without
inlining anything and without a virtual DOM. The fallback is sound by construction and costs one
small allocation per escaping root per render.

**What the pass reports** (W29's rule-7 mitigation): a `dump` stage that lists each hole as
*direct* or *block*.

### 4.3 Components are plain functions of props, and a free memo boundary

`<Row row={r} selected={s}/>` calls `Row : { row : Row, selected : Bool } -> Html msg`. Because
beni functions are pure, **equal arguments give an equal result**, so the slot skips the call
entirely when every prop is `===` to the previous render's. That is the `lazy` that W27 retires,
applied automatically at the boundary the programmer already drew.

Across modules the slot does not need to see `Row`'s body. `Row` returns a block, and the block's
`t` is `Row`'s root site, so no interface change is needed. Within a module, or when inlining is
cheap, the call compiles to `Row$m` and `Row$p` directly.

One caveat. A prop that is a message built during render, such as `onPick={Picked item.id}`, is a
fresh object every time and defeats the skip. beni derives `eq` for data, so message-valued props
*can* be compared structurally, which Solid cannot do. Whether they should be is Q7.

### 4.4 Lists: `For` keyed by a key, by position, or by reference

Solid 2's `For` takes `keyed` absent or `true` (by reference), `false` (by position, the old
`Index`) or a key function (`solid/packages/solid/src/client/flow.ts:63-109`).

- **A key function**, `<For each={model.rows} key={.id}>`, is P2's list hole: a `key → instance`
  map, per-row `row$p`, a `moved` flag, and dom-expressions' `reconcileArrays` without `$$SLOT`
  (`rt/reconcile.js:1-158`). A changed row keeps its DOM, so focus and input state follow it. This is
  the form the benchmark needs.
- **By position** (`keyed={false}`): slot *i* patches with item *i*. Cheap. State stays with the
  position.
- **By reference**, Solid's default, is correct in beni, but with an immutable model it means **any
  change to a row remounts that row**. `{ r | label = … }` is a new object and therefore a new key.
  In Solid, stores mutate in place and keep proxy identity, so this is fine there. Solid's own
  audit notes the same effect for shallow lists: "Shallow reference-keyed lists rebuild replaced
  records" (`solid/documentation/proposals/keyed-list-driver.md`). The default is Q4.

Before calling the row function, the slot compares the item and the row's `env` by `===`. With
the model unchanged this skips the row entirely. When `selected` changes, every row re-runs its
class test. That is P2's 1.71 ms on `select`, still ahead of Solid 2's 2.60, and it is where R3's
field analysis applies later.

### 4.5 Conditionals and `Show`

`if`/`case` in a hole yields blocks from different sites. The slot patches when the branch is the
same and remounts when it changes, which is non-keyed `Show` semantics with no `memo`. **A block's
identity must be its site, not its deduplicated markup.** Otherwise `if c then <input/> else
<input/>` would carry one element's focus and value into the other branch, which Solid never does
because it rebuilds. Templates may still share one `template()` declaration by markup; only the
*kind* identity is per site. `Show` itself is kept as sugar (W29–W33 take Solid's names). Its keyed
form remounts when `when`'s identity changes. `Switch`/`Match` is `case`.

### 4.6 Events

- **Delegated:** the same property write as Solid's (`c/dom/events.rs:60-66`). The stored value is
  a message, or a function from the platform-declared payload to a message. The dispatcher calls it
  and then `send`s the result. `p` rewrites the property only when the hole's value changed.
- **Non-delegated:** Solid's `addEventListener(name, handler)` (`c/dom/events.rs:103-107`)
  attaches the handler itself once. In TEA the handler changes between renders, so beni attaches
  **one stable stub** at mount that reads the node's current handler field. This is the only
  workable design when closures cannot be compared (`plans/browser-platform.md` §2.3).
- **`delegateEvents`** moves from each module's top level to program start (§0 item 9c).
- **W34's "the handler gets the event and calls `preventDefault` itself"** needs a `sync` handler
  that performs an effect. It therefore waits on the effects work. Until then a handler returns a
  message only (Q5).

### 4.7 The runtime, and the experiment that sized it

**Decision: write a small beni runtime, and port three pieces from dom-expressions** (MIT, © Ryan
Carniato; `references/dom-expressions/LICENSE`):

- `template()`, taken as-is minus the hydration guard (`rt/client.js:140-158`);
- the delegated listener, minus portals, shadow-root retargeting and hydration replay
  (`rt/client.js:1695-1797` is 100 lines; beni needs about 15);
- `reconcileArrays` minus `$$SLOT` (`rt/reconcile.js`).

Neither `rt/client.js` nor `rt/universal.js` can be reused whole. Both import `effect`, `memo` and
`createComponent` from an `rxcore` seam (`rt/client.js:2-32`, `rt/universal.js:1-10`), and their
`insert` exists to *be* an effect (`rt/client.js:605-682`).

The experiment is `rt/runtime.js` and `rt/app.js` in the scratchpad. It covers the benchmark view
from R29 §3, written with `<For each={model.rows} key={.id}>` and emitted by hand in §4.2's shape,
plus a page exercising blocks (a helper whose `if` returns one of two templates), a positional list
and text holes. The emitted row:

```js
function row$p(i, row, env) {
  if (i.row === row && i.s === env[0]) return;               // every input the row reads is ===
  const c = row.id === env[0] ? "danger" : "";
  if (c !== i.c) cls(i.el, (i.c = c));
  if (i.row !== row) { const o = i.row;
    if (row.id !== o.id) { i.t1.data = row.id; i.a1.$$click = Select(row.id); i.a2.$$click = Remove(row.id); }
    if (row.label !== o.label) i.t2.data = row.label;
    i.row = row; }
  i.s = env[0];
}
```

Under `linkedom` and Node 24, eleven checks pass: create 1 000; update every 10th, where the
same `<tr>` nodes stay; select, through a delegated `click` and a microtask flush; swap, where the
same nodes move; remove, through a delegated `click`; append; clear; page mount; a branch swap and
list growth, where row 0's node is kept; patch in place within the same branch; and list shrink.

| | minified | brotli 11 |
|---|--:|--:|
| runtime, client part (template, attributes, events, slots, both lists, render loop) | 3 612 | **1 482** |
| runtime with the SSR helpers | 3 752 | 1 577 |
| the whole benchmark app: runtime, view, `update` | 5 403 | **2 201** |
| R29's hand-written P2, for comparison (R29 §12.1) | 4 143 | 1 682 |
| Solid 2.0.0-rc.9, the same app (R29 §12.1) | — | 22 163 |

The sketch carries no vocabulary, no XSS policy beyond `.data`, no after-render phase and no
subscriptions. R29 §12.1's caveat applies: read the *difference* between strategies, about 2 kB
against 22 kB, not the absolute number. linkedom does not parse `<!>` as a comment the way browsers
do (the HTML specification's bogus-comment rule), so the test template spells it `<!---->`. That
is noted in `app.js`.

### 4.8 Where Solid's model does not carry over

| Solid feature | Under TEA | Guarantee or rule-7 note |
|---|---|---|
| local component state (`createSignal` in a component) | none: one model, and components are functions | the programming model is W25. DOM-held state (focus, text, scroll) survives through keyed and site identity |
| context (`createContext`) | pass values explicitly | no owner tree exists |
| `Loading`, `Errored`, `Reveal`, transitions | none: `view` is `sync` and cannot throw | this buys "a render cannot be half-done" (W25's rule-7 check) |
| `ref` | an after-render effect that looks the node up, or a message carrying an opaque element handle for commands | Q6. Refusing a raw mutable ref buys purity of `view` |
| spread on an element | none at first. Later, a record spread of known fields | R27 §6.11 D |
| controlled inputs | a stateful property must compare against the **live DOM value**, not the last value written, or a rejected edit stays on screen. Plus W28's synchronous `flush` | Solid gets this for free: it writes stateful properties with no guard (`c/dom/dynamics.rs:106-124`) |
| `innerHTML` | a platform-declared escape hatch, spelled as one | an escape hatch with a warning, not a refusal (rule 7) |
| hydration | later, as a paired `ssr` and `dom` hydratable build (§5.5) | R27 §6.8: +28 % runtime |

---

## 5. The seam where a platform plugs in a target

*The owner requirement (2026-09-29): platforms must be able to plug into the JSX compiler, for
example so the Node platform can use JSX for server-side rendering, without writing compiler code.*

### 5.1 How dom-expressions does it

Three targets share one front end: the OXC parse, the `JsxTransform` visitor spine
(`c/shared/transform.rs:12-80`), one classification authority (`c/shared/classify.rs:1-11`) and the
shared lowerings behind narrow traits (§3.6). They differ only in element lowering and in the
helper names they emit. `generate` chooses the transform (`c/compiler.rs:164-246`).
`module_name` chooses where the helpers are imported from: `import_named(module_name, …)`
(`c/dom/template.rs:533-545`, `c/universal/helpers.rs:146-147`). A renderer package plugs in by
being that module. It never touches the compiler.

### 5.2 `universal`, the most pluggable form

A custom renderer is `createRenderer({ createElement, createTextNode, createSentinel, isTextNode,
replaceText, insertNode, removeNode, cleanupNodes, setProperty, getParentNode, getFirstChild,
getNextSibling })` (`rt/universal.js:14-27`). The factory returns the helpers the compiler emits:
`insert`, `spread`, `createElement`, `createTextNode`, `insertNode`, `setProp`, `mergeProps`,
`effect`, `memo`, `createComponent`, `ref`, `applyRef` (`rt/universal.js:314-366`). The compiler
imports only those names (`c/universal/transform.rs:260-301`).

**It knows no vocabulary at all.** Tags are strings passed to `createElement`. Attributes *and
events* are props passed to `setProp`, as in `createElement("a", { onClick: … })`
(`c/universal/transform.rs:426-520`). The price is no template cloning: six helper calls where
`dom` makes one (R27 §6.3).

### 5.3 Which targets beni supports

| Target | For | Output shape | First? |
|---|---|---|---|
| **`dom`** | the browser platform | templates, walks, the compiled mount and patch of §4 | **yes** |
| **`ssr`** | the Node platform: server rendering, and `run/` tests of views | string-array templates concatenated with values the compiler has escaped by type | **yes** |
| `universal` | native, canvas, terminal or test renderers | host-operation calls over the same mount and patch | later: the same interface pattern, with no templates |

**The compiler owns the targets**, as fixed lowerings. A platform chooses one. This is Solid's
design with `generate` moved from a build flag into a platform declaration.

### 5.4 What a platform declares

**A manifest key**, beside `program`, `runtime` and `entry` (`boundary.md` §5.2):

```json
"markup": { "target": "dom", "module": "Html", "runtime": "html.js" }
```

- `target` is one of the compiler's lowerings. An unknown value is a manifest error, like
  `invalid_entry_file`.
- `module` is the **vocabulary module**, whose declarations are described next.
- `runtime` is the **markup runtime**: a JavaScript sibling whose exports are the target's
  **well-known entry points**. For `dom` these are `template`, `child`, `forKeyed`, `forIndexed`,
  `attr`, `cls`, `styleProp`, `listen` and `program`. For `ssr` they are `ssr` and `escapeAttr`.
  The list is fixed per target by `backend.md`. The compiler asks for these names the way it asks
  for `eq` and `compare` (`static-dispatch-spike.md` §3.2), and checks export coverage and arity
  the way `boundary.md` §4's checks 2 and 4 already do. It never parses the JavaScript.

**The vocabulary module** is beni source in the platform package, declaring:

- the opaque markup type, `pub foreign type Html msg`, which every JSX expression has;
- **elements**, each with the facts lowering needs: void or not, and namespace (html, svg or
  mathml);
- **attributes**, each with its value type and its write kind: attribute, property, style
  property, class, or stateful property;
- **events**, each with its payload type and whether it is delegated;
- **the list components** `For` and `Show`, as well-known names.

These cannot be ordinary `foreign` values. §4 check 2 would demand a JavaScript export for each
one, and they have no run-time existence. So this needs **a declaration form legal only in platform
packages that carries no JavaScript**. The syntax is Q1.

**What stays in the compiler:** the `dom` target's knowledge of the HTML parser, meaning void
elements, the elements whose end tag the parser implies, table foster-parenting and nested
`<a>`/`<form>`. Those are facts about `innerHTML`, not about any platform's vocabulary. The
compiler's rule for them can be the one Solid enforces with `html5ever`
(`c/shared/validate.rs:23`), done as a small fixed table, or emitted conservatively by always
closing tags. Q2.

**How the checker reads it.**

- A lower-case tag resolves in the platform's vocabulary module. A capitalised tag resolves as an
  ordinary name (W31).
- An attribute resolves in the element's declarations, then the global ones. An unknown attribute
  is `unbound_variable` with "did you mean" (R28 §5.2).
- A value is checked against the declared type. A handler is checked as `msg` or
  `payload -> msg`.
- Children discharge a `renderable` obligation (the `interpolatable` pattern, `checker-v2.md`
  §4.5).
- The checker records each hole's kind in the dispatch table, because **the backend sees no
  types** (`backend.md` §3). The kinds are text, html, list, maybe, attribute of a given write
  kind, event (message or function), component, `For` and `Show`.

**How the emitter reads it.** It looks up `target`, which picks the lowering. It imports the
well-known names from `_platform/<runtime>`. Element facts come from the vocabulary, recorded by
the checker.

### 5.5 One program, two targets

A build is per entry point and per platform (`boundary.md` §5.3). So a shared module holding
`view` compiles twice: `dom` code under the browser platform and `ssr` code under Node.

- **One vocabulary.** Both platforms depend on **one vocabulary package**: "platforms are packages
  and packages depend on packages" (`boundary.md` §5.1). `Html msg` and every element are then the
  same beni names on both, and `view` type-checks identically. Only the manifest's `target` and
  `runtime` differ.
- **The Node platform's SSR runtime** is about 30 lines. `ssr(tpl, …holes)` concatenates.
  `escapeAttr` handles the attribute cases. An `Html msg` value is `{ t: string }`, as in Solid
  (`rt/server.js:2601`). Text escaping comes from types, not run-time checks: a `String` hole gets
  `escape(s)` at compile time, an `Html` hole splices `.t`, and events and refs are dropped (as
  `c/ssr/transform.rs:1741-1760`). `For` becomes a map and join, and `Show` a conditional.
  `Node.printHtml : Html msg -> Program`, or `Html.toString`, makes a view printable. **This is
  also R28 §8.3's requirement that `run/` can test views under Node, met without a new test
  boundary.**
- **Hydration**, later, is a third pairing: `ssr` hydratable emits markers, and `dom` hydratable
  claims nodes instead of cloning them (`c/dom/element.rs:449-461`, `c/dom/children.rs:636-681`).
  It is a target *variant* the platform opts into, not new platform code.

### 5.6 Why this does not widen the `foreign` wall

- **Nothing the platform ships runs inside the compiler.** It ships beni declarations, which are
  data the checker reads, and a JavaScript sibling, which is code the *output* runs.
- The sibling goes through §4's existing checks: export coverage, import coverage, and the arity
  of each well-known entry point.
- The new declaration form carries no JavaScript, so it cannot reach a host global. It is
  privileged like `foreign`: only a platform package may write it. That is the same authority rule
  that already governs `Program`.
- Choosing a target picks among lowerings the compiler already has. It does not add one, so "a
  platform cannot extend the compiler" stays literally true.
- The one new surface is the list of well-known entry points per target. Like
  `eq`/`compare`, it is part of the compiler's contract, versioned with it and written in
  `backend.md`.

---

## 6. Mapping onto beni's pipeline

| Stage | What it does for JSX | Notes |
|---|---|---|
| **Lexer** (`src/lex/Tokenizer.zig`, 1 999 lines) | W30's bare text needs a **JSX mode stack**: tag mode (names may contain hyphens; `{…}` spreads), children mode (text runs up to `<` or `{`), and expression mode inside `{}`. This generalises the existing `string`/`interp` modes with brace depth (`Tokenizer.zig:57-80`) | Where may `<` open a tag? Only when the **previous token cannot end an operand**. That is R28 §3.3–§3.4's rule stated in the lexer, and it keeps `f a <b` a comparison. `--` inside text is text. A `jsx_text` token's length can be re-derived by scanning to the next `<` or `{`, so the two-column cache (`frontend.md` §3.2) holds. Whitespace follows `trim_jsx_text` exactly (`c/shared/utils.rs:210-242`), which is now a specification by port |
| **Parser and AST** | `parseElement` at operand start, attributes, children, fragments, `</Tag>` matching, and recovery | R28 §3's arguments are unchanged. `element_as_argument` stays |
| **Formatter** | Print elements. Whitespace in bare text is significant, so the formatter may re-indent but never re-flow text | This is the price of W30 (R28 §4.2): a test that formats and then renders must show identical output |
| **BIR** | A **dedicated element node** holding the tag reference, attributes and children with names resolved. It is not desugared into calls | W32: JSX is the template compiler. R28 §8.1's lowering (i) is withdrawn |
| **Checker** | Resolve the vocabulary, type attributes, events and components, discharge `renderable`, and record hole kinds in the dispatch table | `For`/`Show` are well-known names (§5.4) |
| **Backend** | New `src/js/Markup.zig`: build the template string (escaping, voids, closing tags), walks and markers (§3.3), `m` and `p` per template kind, blocks at escaping sites, component and `For` slots | It emits ordinary `JsIr`: template literals, member chains, assignments and object literals. Hoisted `template()` constants are pure at load, because `template()` is lazy (`rt/client.js:150-158`) |
| **`Reach`** | Template constants and runtime imports are ordinary edges | A runtime sibling is kept whole if any export survives (`backend.md` §9), so the markup runtime should be split into small siblings: templates and slots, keyed list, SSR |
| **`Opt`, `Rename`, `Print`** | Walk declarations are member chains, so the single-use fold (`backend.md` §9 item 1) may inline them. It is safe only because its "nothing evaluated in between" condition holds: walks precede operations (`c/dom/element.rs:429-433`) | Pin this with an `emit/release/` golden. **No pass may merge or reorder DOM reads past writes** |
| **Determinism** | Template names come from module index plus source order, and kind identity comes from the source site. There is no shared counter | dom-expressions numbers per file in traversal order (`c/shared/utils.rs:471-495`). beni's rule 5 needs the same property, stated in the spec (R28 §9.3) |
| **Field identity (W27)** | `===` on a hole's input means "deeply unchanged" only because a record update is a spread | Every `p` relies on it. The `emit/` and `refEq` fixtures of `browser-platform.md` L3 still apply |

---

## 7. Cost and plan

Each slice is specified first (rule 1). New sections are appended and never renumbered (rule 2):
`language.md` §11 (JSX), `frontend.md` §9, `boundary.md` §9 (markup targets) and **`backend.md`
§15** (template lowering), because §11 is taken. Line counts are Zig unless marked. They are
anchored on R28 §9.1's per-phase estimates, adjusted for bare text (W30) and templates as the only
lowering (W32).

| # | Slice | Size | The tests that prove it |
|---|---|---|---|
| **J0** | **Specification.** Grammar, bare-text whitespace (the port of `trim_jsx_text`), the tag rule, the vocabulary declaration form, the manifest `markup` key, hole kinds, `backend.md` §15's shapes (template kind, block, slots, `For` modes) and the well-known entry points per target | documents only | reviewed against this report's §2 examples |
| **J1** | **Lexer modes** for tags, text and expressions; hyphenated names; spread | 350–450 | `parse/` token dumps covering `a <b`, `f a <b`, text containing `--` and `'`, and nested `{}`. `bench` shows no regression on markup-free code |
| **J2** | **Parser, AST, formatter and dump** | 1 000–1 250 | `parse/` AST goldens. `fmt/` idempotence on bare text, including a golden where text whitespace must not move. `check/bad` for `unclosed_element` and `mismatched_closing_tag` |
| **J3** | **Vocabulary and manifest:** the declaration form, resolution, the `markup` key, and the export and arity checks on the runtime sibling | 400–600 | `check/bad` for unknown targets, missing entry points and wrong arity, plus "did you mean" on an unknown attribute |
| **J4** | **Checker:** elements, attributes, events and components; `renderable`; hole kinds in the dispatch table | 700–1 000, plus 200–300 of diagnostics | a `check/bad` fixture per code. The R28 §11.2 typeahead checks with no `Html.text` wrapper |
| **J5** | **SSR target plus the Node markup runtime** (about 30 lines of JavaScript) | 500–700 | **`run/` renders views to strings under Node**: text and attribute escaping, `For`, `Show`, components and fragments. **This is the first slice that executes JSX**, and the rest are measured against it |
| **J6** | **DOM target:** templates, walks, markers, `m`/`p`, blocks, component slots, events. Plus the browser platform's runtime (about 300 lines of JavaScript, from §4.7) | 1 300–1 700 | `emit/` and `emit/release/` goldens for the shapes in §2.1–§2.11, **development output unchanged by `--release`** apart from printing. **A differential oracle:** translate the 16 `__dom_fixtures__` inputs (1 237 lines, `packages/babel-plugin-jsx/test/`) and compare beni's template strings and walks with the ones the built compiler emits. `browser/` tests follow |
| **J7** | **`For` (key, position, reference) and `Show`**, with keyed reconciliation | 300–400 | `browser/`: a reordered keyed list keeps a focused input in its row, and fails when the list is positional. A branch swap does not carry an `<input>`'s value across (§4.5). A controlled input reverts a rejected edit |
| **J8** | **End to end against Solid 2.** R29's benchmark app written in beni JSX, compiled by beni and measured with R29's harness beside Solid 2.0.0-rc.9 in the same batch | — | the per-operation table in `browser-platform.md` R1, with its four reading rules. R29's E1 static-heavy page. Size against Solid 2's 22 163 brotli |
| later | hydration pairing; `ref` (Q6); spread of known fields; `universal`; R3's field analysis (W42) | — | — |

**Total:** about 4 500–6 000 lines of Zig and about 350 lines of JavaScript runtime.

**Order.** J5 comes before J6 deliberately. It exercises the whole front end (J1–J4) and the
vocabulary seam with a runtime of 30 lines, and it gives rule 3 its `run/` coverage before any
browser exists. J6 through J8 need the `browser/` test kind (`browser-platform.md` B0).

---

## 8. Questions that are the owner's

1. **The vocabulary declaration form.** Should the platform write new keywords
   (`pub element div : Flow`, `pub attribute class : String`, `pub event onClick : Mouse
   delegated`), or reuse `foreign` with core-owned marker types, which would exempt those
   declarations from §4 check 2? *Recommend new keywords:* they say what they are, and they leave
   check 2 exact.
2. **Where HTML-parser knowledge lives.** Option (a) puts void elements, implied end tags and
   foster-parenting in the `dom` target as a fixed table. Option (b) has the platform declare
   content categories, so misnesting becomes a type error (R27 §6.12). *Recommend (a) now and (b)
   later.* (a) is Solid's own rule, a small table instead of `html5ever`. (b) is a real typing
   project.
3. **The block fallback (§4.2) as W29's settled shape.** R29 measured blockdom and P2, but nobody
   has measured a mixed program. *Recommend* accepting it on that evidence and publishing J8 with a
   helper-heavy page (X1's "idiomatic" variant) alongside the table.
4. **`For`'s default keying** in an immutable language. *Recommend* keeping Solid's three modes,
   but with no silent default: `key={…}`, `keyed={false}` or an explicit `byReference`, with a
   warning (not an error, rule 7) when a `For` over records has none.
5. **Handler shape before effects land.** *Recommend* `msg | payload -> msg` now. W34's "calls
   `preventDefault` itself" arrives with `sync` effects, since the handler is where that effect
   runs.
6. **`ref`.** *Recommend* not porting the mutable-variable form. Instead, an element handle
   delivered as a message, usable only in commands, beside W28's after-render phase.
7. **Structural comparison of message-valued component props** (§4.3). *Recommend* identity only
   at first, and measure before adding `eq`.

---

## 9. Could not determine

- **The performance of a compiler-emitted mixed program** (§4.2's blocks inside direct templates).
  The evidence is two endpoints: blockdom and P2. J8 measures it.
- **Throughput of JSX lexing under a mode stack** against the 250k LOC/s budget. No markup-heavy
  corpus exists (R28 §15). J1 has to add one.
- **Whether Chrome and linkedom agree** beyond the `<!>` difference in §4.7. The experiment is a
  correctness smoke test, not a browser test.
- **Solid 2's compiler throughput on this tree.** R27 §6.9 measured the later tree at 271k LOC/s.
  It was not re-measured here.

---

## 10. Evidence index

Scratchpad:
`/tmp/claude-1000/-home-canassa-src-github-com-canassa-beni/34a0b1f8-8c70-4b52-95dc-f0884dce8bed/scratchpad/jsxstudy/`

| Path | What it is |
|---|---|
| `compiler/` | the copied crate. `examples/jsxc.rs` wraps `compile()`, and `target/release/examples/jsxc <file> [ssr\|universal\|hydratable\|noeffect nomemo]` runs it |
| `ex/01…14-*.jsx` | the fourteen inputs of §2 |
| `out-dom.txt`, `out-dom-wrapperless.txt`, `out-ssr.txt`, `out-universal.txt` | the compiler's outputs for every input |
| `rt/runtime.js` (259 lines), `rt/app.js` (90), `rt/test.mjs` | §4.7's runtime, the hand-emitted app and the eleven-check test. Run with `nix shell nixpkgs#nodejs_24 -c node test.mjs` in `rt/` |
| `rt/rtc.min.js`, `rt/app.min.js` | the minified files behind §4.7's size table |
