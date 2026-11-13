// blind5c.mjs <outdir> [filter]: research report 121, a fifth blind test of the ownership checker v3, by
// reader C. It reads the kernel's rules against the code that implements them, and probes the places where
// a negative fact ("no other holder", "no escape") could be assumed rather than derived:
//
// - `pair`: the entry rule (kernel §6.13) on `browser-tea`'s `Tea.element`, whose `update` answers a pair
//   `( model, Cmd msg )`. The model is a tuple or a record. `pair.<model>.<maker>.<twin>`: the maker puts
//   one list at two places of the model (`init` or `update`), or a top-level list into it.
// - `nocode`: a function of the program's record that has no known code where the record is made (one of
//   two functions, the answer of a call, a field of a record, …). `nocode.<role>.<form>.<platform>.<twin>`:
//   the role is `view` (the markup gives an outer element a message that holds a model list, and a click
//   on an inner button runs `update` first) or `settle` (`Browser.hosted`'s `settle` puts a model list at
//   a second field once).
// - `hole`: a hole of markup that reads a local list through a closure made in the hole, then a push onto
//   the list before the markup is answered (kernel §6.12). `hole.<form>.<platform>.<twin>`.
// - `row`: a `For` row's or a `Show` body's parameter put in an event's message (kernel §6.12).
//   `row.<source>.<platform>.<twin>`.
// - `derived`: a derived `eq` or `compare` through generic types of other modules (kernel §6.11), where
//   the part's own `eq` writes its operand. `derived.<shape>.<op>.<twin>`.
// - `fold`: the fold rule (kernel §6.8): a callback that answers its accumulator, a part of it, or the
//   element, at one or two places. `fold.<fold>.<answer>.<twin>`.
// - `limit`: a type near the 4 096-location limit (kernel §8). `limit.<depth>.<twin>`.
//
// The twin is `live` (the program reads the other holder after the write: an in-place write is wrong) or
// `dead` (nothing reads it: the program is safe, and a refusal is a precision loss). See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind5c.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name}${params ? ' ' + params : ''} =\n${ind(body, 4)}\n`;
const list = [];
function emit(name, files) {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(files)) fs.writeFileSync(path.join(d, f), text);
  list.push(path.resolve(d));
}
const join = (...parts) => parts.filter(Boolean).join('\n\n') + '\n';

// ---- pair: the entry rule when `update` answers `( model, Cmd msg )` -----------------------------------

// A model: its type, how `update` takes it apart and puts it back, and what the view shows.
// `a` is the list `update` pushes onto; `b` is the other holder.
const MODELS = {
  t2: { ty: 'List Int × List Int', pat: '( a, b )', mk: (a, b) => `( ${a}, ${b} )` },
  t3: { ty: 'List Int × Int × List Int', pat: '( a, k, b )', mk: (a, b) => `( ${a}, 0, ${b} )` },
  tnest: { ty: '( List Int × Int ) × List Int', pat: '( ( a, k ), b )', mk: (a, b) => `( ( ${a}, 0 ), ${b} )` },
  trec: { ty: '{ a : List Int } × List Int', pat: '( r, b )', mk: (a, b) => `( { a = ${a} }, ${b} )`, get: 'r.a' },
  // The control: a record, whose locations are not below the pair's first.
  rec: { ty: '{ a : List Int, b : List Int }', pat: 'm', mk: (a, b) => `{ a = ${a}, b = ${b} }`, get: 'm.a', getb: 'm.b' },
};
// A maker: `init`'s model and `update`'s answer, for the live and the dead twin.
const MAKERS = {
  // One new list at two places of `init`'s model.
  initdup: { live: { init: (M) => `xs = [ 1, 2 ]\n${M.mk('xs', 'xs')}`, upd: (M, a, b) => M.mk(`List.push ${a} 7`, b) },
             dead: { init: (M) => M.mk('[ 1, 2 ]', '[ 1, 2 ]'), upd: (M, a, b) => M.mk(`List.push ${a} 7`, b) } },
  // A top-level list in `init`'s model.
  inittop: { live: { init: (M) => M.mk('base', '[ 1 ]'), upd: (M, a, b) => M.mk(`List.push ${a} 7`, b), top: true },
             dead: { init: (M) => M.mk('List.copy base', '[ 1 ]'), upd: (M, a, b) => M.mk(`List.push ${a} 7`, b), top: true } },
  // `update` answers its list at both places, then pushes onto one of them next time.
  upddup: { live: { init: (M) => M.mk('[ 1, 2 ]', '[]'), upd: (M, a, b) => `if List.length ${b} == 0 then\n    ${M.mk(a, a)}\n\nelse\n    ${M.mk(`List.push ${a} 7`, b)}` },
            dead: { init: (M) => M.mk('[ 1, 2 ]', '[]'), upd: (M, a, b) => `if List.length ${b} == 0 then\n    ${M.mk(a, `List.copy ${a}`)}\n\nelse\n    ${M.mk(`List.push ${a} 7`, b)}` } },
};
for (const [mn, M] of Object.entries(MODELS)) for (const [kn, K] of Object.entries(MAKERS)) for (const twin of ['live', 'dead']) {
  const k = K[twin];
  const a = M.get ?? 'a';
  const b = M.getb ?? 'b';
  const main = join(
    'import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport List\nimport Sub\nimport Tea',
    `type alias Model =\n    ${M.ty}`,
    'type Msg\n    = Add',
    k.top ? 'base : List Int\nbase = [ 1, 2 ]\n' : '',
    fn('init', '⊤ → Model × Cmd Msg', '⊤', `model =\n${ind(k.init(M), 4)}\n( model, Cmd.none )`),
    fn('update', 'Msg, Model → Model × Cmd Msg', `msg ${M.pat}`, `case msg of\n    Add →\n${ind(`next =\n${ind(k.upd(M, a, b), 4)}\n( next, Cmd.none )`, 8)}`),
    fn('view', 'Model → Html Msg', M.pat, `<div>\n    <output>{List.length ${a}}/{List.length ${b}}${k.top ? `/{List.length base + 0 * List.length ${a}}` : ''}</output>\n    <button onClick={Add}>add</button>\n</div>`),
    'main : Tea.Program\nmain =\n    Tea.element { init = init, update = update, view = view, subscriptions = λ_ → Sub.none }',
  );
  emit(`pair.${mn}.${kn}.${twin}`, { 'Main.beni': main, steps: 'click button\nclick button\nclick button\n', PLATFORM: 'platforms/browser-tea\n' });
}

// ---- nocode: a function of the record that has no known code where the record is made ---------------

// A form: how the field's value is written from the function `f` and a second function `g` of its type.
// Each needs the top-level helpers in `extra`.
const FORMS = {
  direct: { e: (f) => f },
  ifjoin: { e: (f, g) => `if alt then ${g} else ${f}` },
  casejoin: { e: (f, g) => `case pickN of\n    0 →\n        ${f}\n\n    _ →\n        ${g}` },
  callres: { e: (f, g) => `pick ${f} ${g}` },
  field: { e: (f) => `fns.f`, local: (f, g) => `fns = { f = ${f}, g = ${g} }` },
  tuple: { e: (f, g) => `fst ( ${f}, ${g} )` },
  ident: { e: (f) => `ident ${f}` },
  maybe: { e: (f) => `Maybe.withDefault (Just ${f}) ${f}` },
  lambda: { e: (f) => `λx → ${f} x` },
  letalias: { e: () => 'h', local: (f) => `h = ${f}` },
  joinlocal: { e: () => 'h', local: (f, g) => `h = if alt then ${g} else ${f}` },
};
const HELPERS = 'alt : Bool\nalt = False\n\n\npickN : Int\npickN = 0\n\n\npick : a, a → a\npick x y = if alt then y else x\n\n\nident : a → a\nident x = x\n\n\nfst : a × b → a\nfst ( x, _ ) = x\n';
// The two roles. Each is a whole program but for the field's expression.
const VIEW = (plat, twin, field, local) => {
  const hold = twin === 'live' ? 'Report model.items' : 'Report [ List.length model.items ]';
  const tea = plat === 'tea';
  return join(
    `import Browser\nimport Html exposing (Html)\nimport List\nimport Maybe\n${tea ? 'import Tea\n' : ''}`,
    'type Msg\n    = Add\n    | Report (List Int)',
    'type alias Model =\n    items : List Int\n    seen : Int',
    HELPERS,
    fn('update', 'Msg, Model → Model', 'msg model', 'case msg of\n    Add →\n        { model | items = List.push model.items 9 }\n\n    Report l →\n        { model | seen = List.length l }'),
    fn('viewA', 'Model → Html Msg', 'model', `<main>\n    <div id="outer" onClick={${hold}}>\n        <button id="add" onClick={Add}>add</button>\n    </div>\n    <p id="seen">{model.seen}</p>\n</main>`),
    fn('viewB', 'Model → Html Msg', 'model', '<main></main>'),
    `main : ${tea ? 'Tea' : 'Browser'}.Program\nmain =\n${local ? ind(local, 4) + '\n' : ''}    ${tea ? 'Tea.sandbox' : 'Browser.program'}\n        { init = λ⊤ → { items = [ 1, 2 ], seen = 0 }\n        , update = update\n        , view =\n${ind(field, 12)}\n        }`,
  );
};
const SETTLE = (plat, twin, field, local) => join(
  'import Browser exposing (Host)\nimport Html exposing (Html)\nimport List\nimport Maybe\n',
  'type Msg\n    = Add',
  'type alias Model =\n    items : List Int\n    other : List Int',
  HELPERS,
  fn('update', 'Host Msg, Msg, Model → Model', '_ msg model', 'case msg of\n    Add →\n        { model | items = List.push model.items 9 }'),
  fn('settleA', 'Host Msg, Model → Model', '_ model', `if List.isEmpty model.other then\n    { model | other = ${twin === 'live' ? 'model.items' : 'List.copy model.items'} }\n\nelse\n    model`),
  fn('settleB', 'Host Msg, Model → Model', '_ model', 'model'),
  fn('view', 'Model → Html Msg', 'model', '<main>\n    <button id="add" onClick={Add}>add</button>\n    <p id="o">{List.length model.other}</p>\n</main>'),
  `main : Browser.Program\nmain =\n${local ? ind(local, 4) + '\n' : ''}    Browser.hosted\n        { init = λ_ → { items = [ 1, 2 ], other = [] }\n        , update = update\n        , settle =\n${ind(field, 12)}\n        , view = view\n        }`,
);
const ROLES = {
  view: { f: 'viewA', g: 'viewB', make: VIEW, plats: { dom: 'platforms/browser', tea: 'platforms/browser-tea' }, steps: 'click #add\nclick #add\n' },
  settle: { f: 'settleA', g: 'settleB', make: SETTLE, plats: { dom: 'platforms/browser' }, steps: 'click #add\nclick #add\n' },
};
for (const [rn, R] of Object.entries(ROLES)) for (const [form, F] of Object.entries(FORMS)) for (const [pn, pdir] of Object.entries(R.plats)) for (const twin of ['live', 'dead']) {
  let e = F.e(R.f, R.g);
  // A lambda over the record's function: as many parameters as it has.
  if (form === 'lambda') e = rn === 'view' ? `λx → ${R.f} x` : `λh m → ${R.f} h m`;
  const local = F.local ? F.local(R.f, R.g) : '';
  emit(`nocode.${rn}.${form}.${pn}.${twin}`, { 'Main.beni': R.make(pn, twin, e, local), steps: R.steps, PLATFORM: `${pdir}\n` });
}

// ---- derived: a derived method through generic types of other modules ---------------------------------

const TM = `import List


pub type T
    = T (List Int)


${fn('eq', 'T, T → Bool', 'x y', 'case ( x, y ) of\n    ( T a, T b ) →\n        List.length (List.push a 0) == List.length b')}

${fn('compare', 'T, T → Order', 'x y', 'case ( x, y ) of\n    ( T a, T b ) →\n        Basics.compare (List.length (List.push a 0)) (List.length b)')}`.replace(/^eq :/m, 'pub eq :').replace(/^compare :/m, 'pub compare :');
const BX = 'pub type Box a\n    = Box a\n\n\npub type Pair a b\n    = Pair a b\n';
const WM = 'import Tm exposing (T)\n\n\npub type W\n    = W T Int\n';
const DSHAPES = {
  box2: (q) => `Box (Box (T ${q}))`,
  boxpair: (q) => `Pair 1 (Box (T ${q}))`,
  tupbox: (q) => `( Box (T ${q}), 1 )`,
  maybebox: (q) => `Just (Box (T ${q}))`,
  boxw: (q) => `Box (W (T ${q}) 1)`,
  recbox: (q) => `{ a = Box (T ${q}) }`,
  listbox: (q) => `[ Box (T ${q}) ]`,
  resbox: (q) => `Ok (Box (T ${q}))`,
};
const DOPS = {
  eq: (a, b) => `if ${a} == ${b} then "eq" else "ne"`,
  lt: (a, b) => `if ${a} < ${b} then "lt" else "ge"`,
  sort: (a, b) => `String.fromInt (List.length (List.sort [ ${a}, ${b} ]))`,
  member: (a, b) => `if List.member [ ${a} ] ${b} then "in" else "out"`,
};
for (const [sn, mk] of Object.entries(DSHAPES)) for (const [on, op] of Object.entries(DOPS)) for (const twin of ['live', 'dead']) {
  // `Result` and records have no `compare`: only `==` and `List.member` for them.
  if ((sn === 'resbox' || sn === 'recbox') && (on === 'lt' || on === 'sort')) continue;
  const body = `xs = [ n ]\nr =\n${ind(op(`(${mk('xs')})`, `(${mk('[ 5 ]')})`), 4)}\nr ++ "/" ++ show ${twin === 'live' ? 'xs' : '[ 4 ]'}`;
  const main = join(
    'import Bx exposing (Box, Pair)\nimport List\nimport Node exposing (Program)\nimport String\nimport Tm exposing (T)\nimport Wm exposing (W)',
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('go', 'Int → String', 'n', body),
    'main : Program\nmain =\n    Node.print (go 1)',
  );
  emit(`derived.${sn}.${on}.${twin}`, { 'Main.beni': main, 'Tm.beni': TM, 'Bx.beni': BX, 'Wm.beni': WM });
}

// ---- fold: what the callback answers, which the fold hands back -------------------------------------

const FOLDS = {
  foldl: (init, cb) => `List.foldl [ 1, 2, 3 ] ${init} λx acc →\n${ind(cb, 4)}`,
  walk: (init, cb) => `walk [ 1, 2, 3 ] ${init} λx acc →\n${ind(cb, 4)}`,
};
const WALK = fn('walk', 'List Int, a, (Int, a → a) → a', 'xs acc f', 'case xs of\n    [] →\n        acc\n\n    [ x, …rest ] →\n        walk rest (f x acc) f');
// An answer: the accumulator's type, its first value, the callback's body, and what the result shows.
// The live twin answers one list at two places of the accumulator, or one it let go; the dead one does not.
const ANSWERS = {
  pairdup: { ty: 'List Int × List Int', init: '( [ 0 ], [ 0 ] )', live: 'case acc of\n    ( a, b ) →\n        ( List.push a x, a )', dead: 'case acc of\n    ( a, b ) →\n        ( List.push a x, List.copy a )', show: (r) => 'case r of\n    ( a, b ) →\n        show a ++ "|" ++ show b' },
  recdup: { ty: '{ a : List Int, b : List Int }', init: '{ a = [ 0 ], b = [ 0 ] }', live: '{ a = List.push acc.a x, b = acc.a }', dead: '{ a = List.push acc.a x, b = List.copy acc.a }', show: (r) => 'show r.a ++ "|" ++ show r.b' },
  newdup: { ty: 'List Int × List Int', init: '( [ 0 ], [ 0 ] )', live: 'case acc of\n    ( a, _ ) →\n        k = List.push a x\n        ( k, k )', dead: 'case acc of\n    ( a, _ ) →\n        k = List.push a x\n        ( k, List.copy k )', show: (r) => 'case r of\n    ( a, b ) →\n        show (List.push a 9) ++ "|" ++ show b' },
  keepnest: { ty: 'List (List Int)', init: '[ [ 0 ] ]', live: 'List.push acc (Maybe.withDefault (List.head acc) [])', dead: 'List.push acc [ x ]', show: (r) => 'String.join (List.map r show) ";"' },
};
for (const [fname, F] of Object.entries(FOLDS)) for (const [an, A] of Object.entries(ANSWERS)) for (const twin of ['live', 'dead']) {
  const body = `r =\n${ind(F(A.init, A[twin]), 4)}\n${A.show('r')}`;
  const main = join(
    'import List\nimport Maybe\nimport Node exposing (Program)\nimport String',
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fname === 'walk' ? WALK : '',
    fn('go', '⊤ → String', '⊤', body),
    'main : Program\nmain =\n    Node.print (go ⊤)',
  );
  emit(`fold.${fname}.${an}.${twin}`, { 'Main.beni': main });
}

// ---- limit: a type near the location limit ------------------------------------------------------------

// `( x, x )` nested d times over `List Int`: 2^d locations. 12 is at the limit, 13 past it.
for (const d of [11, 12, 13]) for (const twin of ['live', 'dead']) {
  const aliases = [];
  let prev = 'List Int';
  for (let i = 0; i < d; i++) { aliases.push(`type alias P${i} =\n    ${prev.includes(' ') ? `(${prev})` : prev} × ${prev.includes(' ') ? `(${prev})` : prev}`); prev = `P${i}`; }
  let val = 'xs';
  for (let i = 0; i < d; i++) val = `( ${val}, ${val} )`;
  const top = `P${d - 1}`;
  const body = `xs = [ n ]\nbig = ${val}\nys = List.push ${twin === 'live' ? 'xs' : 'zs'} 2\n"${'${'}String.fromInt (List.length (first big))}/${'${'}String.fromInt (List.length ys)}"`;
  const pat = (k) => (k === 0 ? 'l' : `( ${pat(k - 1)}, _ )`);
  const main = join(
    'import List\nimport Node exposing (Program)\nimport String',
    ...aliases,
    fn('first', `${top} → List Int`, 'b', `case b of\n    ${pat(d)} →\n        l`),
    fn('go', 'Int → String', 'n', twin === 'dead' ? `zs = [ n ]\n${body}` : body),
    'main : Program\nmain =\n    Node.print (go 1)',
  );
  emit(`limit.d${d}.${twin}`, { 'Main.beni': main });
}

// ---- hole: what a hole of markup reads, when the lowering evaluates it where it renders ----------------

// A hole: an expression of type Int that reads the local list xs. The view makes markup with it, then
// pushes onto xs in place (live) or onto a copy (dead), then answers the markup.
const HOLES = {
  local: 'List.length xs',
  lambda: '(λ⊤ → List.length xs) ⊤',
  letfn: 'len ⊤',
  maybemap: 'Maybe.withDefault (Maybe.map (Just 1) λ_ → List.length xs) 0',
  listmap: 'List.sum (List.map [ 1 ] λ_ → List.length xs)',
  ifelse: 'if alt then 0 else (λ⊤ → List.length xs) ⊤',
  helper: 'count (λ⊤ → List.length xs)',
  record: '({ f = λ⊤ → List.length xs }).f ⊤',
};
const HPLATS = { dom: 'platforms/browser', tea: 'platforms/browser-tea' };
for (const [hn, h] of Object.entries(HOLES)) for (const [pn, pdir] of Object.entries(HPLATS)) for (const twin of ['live', 'dead']) {
  const tea = pn === 'tea';
  const hole = h.includes('\n') ? '\n' + ind(h, 8) + '\n    ' : h;
  const main = join(
    `import Browser\nimport Html exposing (Html)\nimport List\nimport Maybe\n${tea ? 'import Tea\n' : ''}`,
    'type Msg\n    = Add',
    'type alias Model =\n    items : List Int',
    'alt : Bool\nalt = False\n',
    fn('count', '(⊤ → Int) → Int', 'g', 'g ⊤'),
    fn('update', 'Msg, Model → Model', 'msg model', 'case msg of\n    Add →\n        { model | items = List.push (List.copy model.items) 1 }'),
    fn('view', 'Model → Html Msg', 'model', `xs = List.copy model.items\nlen = λ⊤ → List.length xs\nm = <p id="m">{${hole}}</p>\nys = List.push ${twin === 'live' ? 'xs' : '(List.copy xs)'} 5\n<main>\n    <button id="add" onClick={Add}>add</button>\n    {m}\n    <p id="y">{List.length ys}</p>\n</main>`),
    `main : ${tea ? 'Tea' : 'Browser'}.Program\nmain =\n    ${tea ? 'Tea.sandbox' : 'Browser.program'} { init = λ⊤ → { items = [ 1, 2 ] }, update = update, view = view }`,
  );
  emit(`hole.${hn}.${pn}.${twin}`, { 'Main.beni': main, steps: 'click #add\n', PLATFORM: `${pdir}\n` });
}

// ---- row: a For row's or a Show body's parameter, kept by a handler -----------------------------------

// The runtime calls a For's row function with each item of its list, and a Show's body with its value.
// The body puts its parameter in an event's message; a click on an inner button runs update, which writes
// the model's list in place, and the click bubbles to the outer element, whose message holds the list.
// A row: the model's field, init's value, update's write, and the markup around the body.
const ROWS = {
  forfield: { ty: 'List (List Int)', init: '[ [ 1, 2 ] ]', write: 'List.update model.v 0 λr → List.push r 9', open: '<For each={model.v} keyed={False}>', close: '</For>' },
  forkeyed: { ty: 'List (List Int)', init: '[ [ 1, 2 ] ]', write: 'List.update model.v 0 λr → List.push r 9', open: '<For each={model.v} keyed={λr → String.fromInt (List.length r)}>', close: '</For>' },
  forlit: { ty: 'List Int', init: '[ 1, 2 ]', write: 'List.push model.v 9', open: '<For each={[ model.v ]} keyed={False}>', close: '</For>' },
  showfield: { ty: 'Maybe (List Int)', init: 'Just [ 1, 2 ]', write: 'Maybe.map model.v λr → List.push r 9', open: '<Show when={model.v} keyed={λ_ → 0}>', close: '</Show>' },
  showlit: { ty: 'List Int', init: '[ 1, 2 ]', write: 'List.push model.v 9', open: '<Show when={if alt then Nothing else Just model.v} keyed={λ_ → 0}>', close: '</Show>' },
};
for (const [rn, R] of Object.entries(ROWS)) for (const [pn, pdir] of Object.entries({ dom: 'platforms/browser', tea: 'platforms/browser-tea' })) for (const twin of ['live', 'dead']) {
  const tea = pn === 'tea';
  const msg = twin === 'live' ? 'Report l' : 'Report [ List.length l ]';
  const main = join(
    `import Browser\nimport Html exposing (Html)\nimport List\nimport Maybe\nimport String\n${tea ? 'import Tea\n' : ''}`,
    'type Msg\n    = Add\n    | Report (List Int)',
    `type alias Model =\n    v : ${R.ty}\n    seen : Int`,
    'alt : Bool\nalt = False\n',
    fn('update', 'Msg, Model → Model', 'msg model', `case msg of\n    Add →\n        { model | v = ${R.write} }\n\n    Report l →\n        { model | seen = List.length l }`),
    fn('view', 'Model → Html Msg', 'model', `<main>\n    ${R.open}\n        {λl →\n            <div class="outer" onClick={${msg}}>\n                <button class="add" onClick={Add}>add</button>\n            </div>\n        }\n    ${R.close}\n    <p id="seen">{model.seen}</p>\n</main>`),
    `main : ${tea ? 'Tea' : 'Browser'}.Program\nmain =\n    ${tea ? 'Tea.sandbox' : 'Browser.program'} { init = λ⊤ → { v = ${R.init}, seen = 0 }, update = update, view = view }`,
  );
  emit(`row.${rn}.${pn}.${twin}`, { 'Main.beni': main, steps: 'click .add\nclick .add\n', PLATFORM: `${pdir}\n` });
}

fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs in ${out}`);
