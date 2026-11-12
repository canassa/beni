// blind4a.mjs <outdir> [filter]: research report 118, a fourth blind test of the ownership checker v3, by
// reader A. Three corners where a fact the verdict depends on negatively was not derived:
//
// - `derived`: a type whose `eq` or `compare` the compiler derives calls the `eq` or `compare` that a
//   part's type declares. That method writes its operand. The derived code is a caller that no walk sees.
//   `derived.<shape>.<op>.<twin>`: the shape holds `T xs` (`T` and its writing method are in `Tm.beni`);
//   the op is `==`, `≠`, `<`, `List.sort` or `List.member`.
// - `fold`: the callback of a fold writes its accumulator in place, and answers a new list that it let
//   escape (into a `Ref`). The fold hands the answer back as the next accumulator, and the write is in
//   place while the `Ref` holds it. `fold.<fold>.<escape>.<twin>`.
// - `entry`: a page program (the `page` test platform, `tests/platforms/page`). The runtime hands `update`
//   a model that the checker calls `own`. `entry.<case>.<twin>`: one list at two places of the model, a
//   model list that a `Ref` keeps, a message whose list a top-level value holds or that is sent twice.
//   These programs have a `steps` file and a `PLATFORM` file; `run.mjs` builds them for that platform
//   and drives them with `tests/browser/driver.mjs` under happy-dom.
//
// The twin is `live` (the program reads the other holder after the write) or `dead` (it does not: the
// program is safe, and a refusal is a precision loss). See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind4a.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name}${params ? ' ' + params : ''} =\n${ind(body, 4)}\n`;
const SHOW = fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","');
const list = [];
function emit(name, files) {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(files)) fs.writeFileSync(path.join(d, f), text);
  list.push(path.resolve(d));
}

// ---- derived: a derived method calls a part's writing method ----------------------------------------

const TM = `import List


pub type T
    = T (List Int)


${fn('eq', 'T, T → Bool', 'x y', 'case ( x, y ) of\n    ( T a, T b ) →\n        List.length (List.push a 0) == List.length b').replace('eq :', 'pub eq :')}

${fn('compare', 'T, T → Order', 'x y', 'case ( x, y ) of\n    ( T a, T b ) →\n        Basics.compare (List.length (List.push a 0)) (List.length b)').replace('compare :', 'pub compare :')}`;
// A shape: the value that holds `T q`, as a function of the list expression.
const SHAPES = {
  tuple: (q) => `( T ${q}, 1 )`,
  record: (q) => `{ a = T ${q} }`,
  maybe: (q) => `Just (T ${q})`,
  result: (q) => `Ok (T ${q})`,
  user: (q) => `W (T ${q}) 1`,
  nested: (q) => `( { a = Just (T ${q}) }, 1 )`,
  tuple3: (q) => `( 1, ( 2, T ${q} ) )`,
  // The control: `T` itself, whose `eq` and `compare` the checker reads where the call is.
  direct: (q) => `T ${q}`,
};
// An op: a `String` expression over two values `a` and `b` of one shape.
const OPS = {
  eq: (a, b) => `if ${a} == ${b} then "eq" else "ne"`,
  ne: (a, b) => `if ${a} ≠ ${b} then "ne" else "eq"`,
  lt: (a, b) => `if ${a} < ${b} then "lt" else "ge"`,
  sort: (a, b) => `String.fromInt (List.length (List.sort [ ${a}, ${b} ]))`,
  member: (a, b) => `if List.member [ ${a} ] ${b} then "in" else "out"`,
};
for (const [shape, mk] of Object.entries(SHAPES)) for (const [op, opf] of Object.entries(OPS)) for (const twin of ['live', 'dead']) {
  const a = `(${mk('xs')})`;
  const b = `(${mk('[ 5 ]')})`;
  const body = `xs = [ n ]\nr =\n${ind(opf(a, b), 4)}\nr ++ "/" ++ show ${twin === 'live' ? 'xs' : '[ 4 ]'}`;
  const main = [
    'import List\nimport Node exposing (Program)\nimport String\nimport Tm exposing (T)\n',
    SHOW,
    shape === 'user' ? 'type W\n    = W T Int\n' : '',
    fn('go', 'Int → String', 'n', body),
    'main : Program\nmain =\n    Node.print (go 1)\n',
  ].filter(Boolean).join('\n\n');
  emit(`derived.${shape}.${op}.${twin}`, { 'Main.beni': main, 'Tm.beni': TM });
}

// ---- fold: the callback answers a list it let escape, and the fold hands it back -------------------

// A fold: `(list, init, callback)` to an expression; the callback takes `x` and the accumulator `acc`.
const FOLDS = {
  foldl: (cb) => `List.foldl [ 1, 2, 3 ] [ 0 ] λx acc →\n${ind(cb, 4)}`,
  foldr: (cb) => `List.foldr [ 3, 2, 1 ] [ 0 ] λx acc →\n${ind(cb, 4)}`,
  dict: (cb) => `Dict.foldl (Dict.fromList [ ( 1, 1 ), ( 2, 2 ), ( 3, 3 ) ]) [ 0 ] λ_ x acc →\n${ind(cb, 4)}`,
  set: (cb) => `Set.foldl (Set.fromList [ 1, 2, 3 ]) [ 0 ] λx acc →\n${ind(cb, 4)}`,
  // A fold the program writes: a tail call that hands the answer back.
  hand: (cb) => `walk [ 1, 2, 3 ] [ 0 ] λx acc →\n${ind(cb, 4)}`,
};
const WALK = fn('walk', 'List Int, List Int, (Int, List Int → List Int) → List Int', 'xs acc f', 'case xs of\n    [] →\n        acc\n\n    [ x, …rest ] →\n        walk rest (f x acc) f');
// How the callback lets its new list `k` escape when `x` is 1.
const ESCAPES = {
  set: (k) => `if x == 1 then\n    Ref.set r ${k}\n`,
  modify: (k) => `_ = if x == 1 then Ref.modify r λ_ → ( 0, ${k} ) else 0`,
  update: (k) => `if x == 1 then\n    Ref.update r λ_ → ${k}\n`,
};
// What the callback writes: the accumulator, in place.
const WRITES = {
  push: '_ = List.push acc x',
  set: '_ = List.set acc 0 x',
};
for (const [fold, mkf] of Object.entries(FOLDS)) for (const [esc, mke] of Object.entries(ESCAPES)) for (const [wr, w] of Object.entries(WRITES)) for (const twin of ['live', 'dead']) {
  const cb = `${w}\nk = [ x ]\n${mke('k')}\nk`;
  const body = `r = Ref.make [ n ]\nout =\n${ind(mkf(cb), 4)}\n${twin === 'live' ? 'show (Ref.get r) ++ "/" ++ show out' : 'show out'}`;
  const main = [
    'import Dict\nimport List\nimport Node exposing (Program)\nimport Ref\nimport Set\nimport String\n',
    SHOW,
    fold === 'hand' ? WALK : '',
    fn('go', 'Int → String', 'n', body),
    'main : Program\nmain =\n    Node.print (go 9)\n',
  ].filter(Boolean).join('\n\n');
  emit(`fold.${fold}.${esc}.${wr}.${twin}`, { 'Main.beni': main });
}

// ---- entry: the model and the message that the runtime hands `update` -------------------------------

const PAGE = (model, init, update, view, msg = 'Int') => [
  'import List\nimport Page exposing (Node)\nimport Ref exposing (Ref)\n',
  model ? `type alias Model =\n${ind(model, 4)}\n` : '',
  fn('init', '⊤ → Model', '_', init),
  fn('update', `${msg}, Model → Model`, 'msg model', update),
  fn('view', `Model → Node ${msg}`, 'model', view),
  'main : Page.Program\nmain = Page.sandbox { init = init, update = update, view = view }\n',
].filter(Boolean).join('\n\n');
const BUTTONS = (msgs, out) => `Page.element "main" []\n    [ ${msgs.map(([id, m]) => `Page.element "button" [ Page.attribute "id" "${id}", Page.onClick (${m}) ] [ Page.text "${id}" ]`).join('\n    , ')}\n    , Page.element "output" [] [ Page.text (${out}) ]\n    ]`;
const len = (e) => `String.fromInt (List.length (${e}))`;
const ENTRY = {
  // One fresh list at two fields of the model, from `init`.
  twofields: {
    model: '{ items : List Int, other : List Int }',
    init: 'xs = [ 1, 2 ]\n{ items = xs, other = xs }',
    update: '{ model | items = List.push model.items msg }',
    reads: { live: 'model.other', dead: 'model.items' },
    steps: 'click #add\nclick #add\n',
  },
  // The same, through a record nested in the model.
  nested: {
    model: '{ items : List Int, inner : { other : List Int } }',
    init: 'xs = [ 1, 2 ]\n{ items = xs, inner = { other = xs } }',
    update: '{ model | items = List.push model.items msg }',
    reads: { live: 'model.inner.other', dead: 'model.items' },
    steps: 'click #add\nclick #add\n',
  },
  // The same, through `Maybe`.
  maybe: {
    model: '{ items : List Int, other : Maybe (List Int) }',
    init: 'xs = [ 1, 2 ]\n{ items = xs, other = Just xs }',
    update: '{ model | items = List.push model.items msg }',
    reads: { live: 'Maybe.withDefault model.other []', dead: 'model.items' },
    steps: 'click #add\nclick #add\n',
  },
  // `update` answers one new list at two fields.
  updtwo: {
    model: '{ items : List Int, other : List Int, step : Int }',
    init: '{ items = [ 1 ], other = [], step = 0 }',
    update: 'if model.step == 0 then\n    ys = List.copy model.items\n    { model | items = ys, other = ys, step = 1 }\n\nelse\n    { model | items = List.push model.items msg }',
    reads: { live: 'model.other', dead: 'model.items' },
    steps: 'click #add\nclick #add\nclick #add\n',
  },
  // `init` keeps its model list in a `Ref` of the model.
  initref: {
    model: '{ items : List Int, keep : Ref (List Int) }',
    init: 'xs = [ 1, 2 ]\n{ items = xs, keep = Ref.make xs }',
    update: '{ model | items = List.push model.items msg }',
    reads: { live: 'Ref.get model.keep', dead: 'model.items' },
    steps: 'click #add\nclick #add\n',
  },
  // `update` puts the model's list in a `Ref`, then a later `update` writes it.
  updref: {
    model: '{ items : List Int, keep : Ref (List Int), step : Int }',
    init: '{ items = [ 1, 2 ], keep = Ref.make [], step = 0 }',
    update: 'if model.step == 0 then\n    Ref.set model.keep model.items\n    { model | step = 1 }\n\nelse\n    { model | items = List.push model.items msg }',
    reads: { live: 'Ref.get model.keep', dead: 'model.items' },
    steps: 'click #add\nclick #add\nclick #add\n',
  },
  // `update` makes a new list, puts it in a `Ref` and answers it.
  updfreshref: {
    model: '{ items : List Int, keep : Ref (List Int), step : Int }',
    init: '{ items = [ 1, 2 ], keep = Ref.make [], step = 0 }',
    update: 'if model.step == 0 then\n    ys = List.copy model.items\n    Ref.set model.keep ys\n    { model | items = ys, step = 1 }\n\nelse\n    { model | items = List.push model.items msg }',
    reads: { live: 'Ref.get model.keep', dead: 'model.items' },
    steps: 'click #add\nclick #add\nclick #add\n',
  },
};
for (const [nm, e] of Object.entries(ENTRY)) for (const twin of ['live', 'dead']) {
  const view = BUTTONS([['add', '7']], len(e.reads[twin]));
  emit(`entry.${nm}.${twin}`, {
    'Main.beni': PAGE(e.model, e.init, e.update, view).replace('import List\n', 'import List\nimport Maybe\n'),
    steps: e.steps,
    PLATFORM: 'tests/platforms/page\n',
  });
}
// The message: its list is a top-level value's, or one message is sent three times in one task.
const MSG = (payload, extra) => [
  'import List\nimport Page exposing (Node)\n',
  'type Msg\n    = Add (List Int)\n',
  extra,
  fn('update', 'Msg, Int → Int', 'msg n', 'case msg of\n    Add l →\n        List.length (List.push l 9)'),
  fn('view', 'Int → Node Msg', 'n', `l = [ n ]\n${BUTTONS([['add', `Add ${payload}`]], 'String.fromInt n')}`),
  'main : Page.Program\nmain = Page.sandbox { init = λ⊤ → 0, update = update, view = view }\n',
].filter(Boolean).join('\n\n');
const BASE = fn('base', 'List Int', '', '[ 5 ]');
for (const [nm, payload, extra, steps] of [
  ['constant', 'base', BASE, { live: 'click #add\nclick #add\n', dead: 'click #add\n' }],
  ['constlocal', 'b', BASE.replace('base', 'b').replace('base', 'b'), { live: 'click #add\nclick #add\n', dead: 'click #add\n' }],
  ['resend', 'l', '', { live: 'click #add 3\n', dead: 'click #add\n' }],
]) for (const twin of ['live', 'dead']) {
  emit(`entry.msg${nm}.${twin}`, { 'Main.beni': MSG(payload, extra), steps: steps[twin], PLATFORM: 'tests/platforms/page\n' });
}

fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
