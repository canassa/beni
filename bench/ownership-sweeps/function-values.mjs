// function-values.mjs <outdir> [filter]: a systematic generator for the ways a function value can travel.
// It was written for research report 112 §6, after the rule for function values was fixed and before any
// program of it ran under a checker. Each program has a callback `cb` of type `Int, List Int → List Int`.
// The callback goes through one carrier (a composition, a record, a tuple, a list, a `Maybe`, a cell, a
// partial application, a function that answers it, a callback that answers a callback, recursion) to one
// runner (a call, two calls, a fold, a nested fold, a map). Programs are
// `<carrier>.<runner>.<act>.<mode>/Main.beni`. See bench/ownership-sweeps/README.md.
//
//   act:  what the callback does with the list that it is handed, or with a list that it captured
//   mode: `live` reads the shared lists after the run; `dead` reads only the result
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/function-values.mjs <outdir> [filter]'); process.exit(2); }

const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;
const CB = '(Int, List Int → List Int)';

// ---------------------------------------------------------------------------------------------
// Acts: the body of the callback, over its parameters `x` and `a`. `q` is a list in scope (a captured
// local, or a parameter of the function that makes the callback). `pre`: lines before the callback that
// its body needs. `after`: what the scenario does with the result `res` (`wrap`: one more list level).
const ACTS = {
  // It writes the list that it is handed.
  push: { body: (x, a) => `List.push ${a} ${x}` },
  // It writes the list, and a task reads the written list later.
  keep: { body: (x, a, dead) => `b = List.push ${a} ${x}\n_ = Task.soon λ⊤ → say (${dead ? '"tick"' : '"kept " ++ show b'})\nb` },
  // It hands a captured list to a captured function that writes its parameter.
  pushcap: { pre: 'p = λl y → List.push l y', body: (x, a) => `_ = p q ${x}\n${a}`, cap: true },
  // It answers a captured list. The scenario writes the answer.
  anscap: { body: () => 'q', cap: true, edit: true },
  // It answers the list that it is handed. The scenario writes the answer.
  same: { body: (x, a) => a, edit: true },
};

const lam = (act, dead) => `λx a →\n${ind(ACTS[act].body('x', 'a', dead), 4)}`;
const lamCurried = (act, dead) => `λx →\n    λa →\n${ind(ACTS[act].body('x', 'a', dead), 8)}`;

// ---------------------------------------------------------------------------------------------
// Carriers: how the callback gets from where it is made to the runner. Each gives the lines that make
// `cb` and carry it (`lines`), the expression that the runner uses (`f`), and top-level helpers (`decls`).
// `own`: the carrier makes the callback itself (a top-level function, a function that answers it).
const H = {
  ident: fn('ident', 'a → a', 'v', 'v'),
  first: fn('first', 'a × b → a', 't', 't.0'),
  comp: fn('comp', '(x, a → b), (x, b → c) → (x, a → c)', 'f g', 'λx a → g x (f x a)'),
  wrap: fn('wrap', `${CB} → ${CB}`, 'f', 'λx a → f x a'),
  ap: fn('ap', `${CB}, Int, List Int → List Int`, 'f x a', 'f x a'),
  useRec: fn('useRec', `{ run : ${CB} }, Int, List Int → List Int`, 'r x a', 'g = r.run\ng x a'),
  runMay: fn('runMay', `Maybe ${CB}, Int, List Int → List Int`, 'mg x a', 'case mg of\n    Just g →\n        g x a\n\n    Nothing →\n        a'),
  ping: fn('ping', `${CB}, Int, List Int → List Int`, 'f m a', 'if m == 0 then a else pong f (m - 1) (f m a)'),
  pong: fn('pong', `${CB}, Int, List Int → List Int`, 'f m a', 'ping f m (f m a)'),
  ufold: fn('ufold', 'List x, a, (x, a → a) → a', 'xs acc f', 'case xs of\n    [] →\n        acc\n\n    [ x, …rest ] →\n        ufold rest (f x acc) f'),
};
const idf = 'λ_ v → v';
// A partial application of `head`, which takes the two parameters of a callback last: one hole, then a call.
const partial = (head) => `g =\n    λx a →\n        h = ${head} x _\n        h a`;
const local = (act, dead) => [...(ACTS[act].pre ? [ACTS[act].pre] : []), `cb =\n${ind(lam(act, dead), 4)}`];

const CARRIERS = {
  // The control: the callback as it is.
  dir: (act, dead) => ({ lines: local(act, dead), f: 'cb' }),
  // Compositions, two and three deep, and a function that answers a function made from its argument.
  comp2a: (act, dead) => ({ lines: local(act, dead), f: `(comp cb ${idf})`, uses: ['comp'] }),
  comp2b: (act, dead) => ({ lines: local(act, dead), f: `(comp (${idf}) cb)`, uses: ['comp'] }),
  comp3: (act, dead) => ({ lines: local(act, dead), f: `(comp (comp cb ${idf}) ${idf})`, uses: ['comp'] }),
  wrap: (act, dead) => ({ lines: local(act, dead), f: '(wrap cb)', uses: ['wrap'] }),
  wrap2: (act, dead) => ({ lines: local(act, dead), f: '(wrap (wrap cb))', uses: ['wrap'] }),
  deep: (act, dead) => ({ lines: local(act, dead), f: `(comp (wrap cb) (comp (${idf}) ${idf}))`, uses: ['comp', 'wrap'] }),
  // Through a type variable.
  ident: (act, dead) => ({ lines: local(act, dead), f: '(ident cb)', uses: ['ident'] }),
  first: (act, dead) => ({ lines: local(act, dead), f: '(first ( cb, 0 ))', uses: ['first'] }),
  // In a record, a tuple, a list, a `Maybe`, a cell.
  rec: (act, dead) => ({ lines: [...local(act, dead), 'r = { run = cb, n = 0 }', 'g = r.run'], f: 'g' }),
  recarg: (act, dead) => ({ lines: [...local(act, dead), partial('useRec { run = cb }')], f: 'g', uses: ['useRec'] }),
  tup: (act, dead) => ({ lines: [...local(act, dead), 't = ( 0, cb )', '( _, g ) = t'], f: 'g' }),
  lst: (act, dead) => ({ lines: [...local(act, dead), 'fs = [ cb ]', 'g = λx a → List.foldl fs a λh b → h x b'], f: 'g' }),
  lst2: (act, dead) => ({ lines: [...local(act, dead), 'fs = [ cb, cb ]', 'g = λx a → List.foldl fs a λh b → h x b'], f: 'g' }),
  may: (act, dead) => ({ lines: [...local(act, dead), 'mg = Just cb', 'g =\n    λx a →\n        case mg of\n            Just h →\n                h x a\n\n            Nothing →\n                a'], f: 'g' }),
  mayarg: (act, dead) => ({ lines: [...local(act, dead), partial('runMay (Just cb)')], f: 'g', uses: ['runMay'] }),
  ref: (act, dead) => ({ lines: [...local(act, dead), 'rf = Ref.make cb', 'g =\n    λx a →\n        h = Ref.get rf\n        h x a'], f: 'g' }),
  // One of two functions.
  join: (act, dead) => ({ lines: [...local(act, dead), `g = if n == 0 then cb else ${idf}`], f: 'g' }),
  // Partial application: of a function that runs the callback, and of a top-level function with the act.
  part: (act, dead) => ({ lines: [...local(act, dead), partial('ap cb')], f: 'g', uses: ['ap'] }),
  parttop: (act, dead) => ({ lines: [partial('stepq q')], f: 'g', own: true,
    decls: [fn('stepq', 'List Int, Int, List Int → List Int', 'q x a', (ACTS[act].pre ? ACTS[act].pre + '\n' : '') + ACTS[act].body('x', 'a', dead))] }),
  // A function that answers the callback, and one that answers a function that answers it.
  ret: (act, dead) => ({ lines: [], f: '(mk q)', own: true,
    decls: [fn('mk', `List Int → ${CB}`, 'q', (ACTS[act].pre ? ACTS[act].pre + '\n' : '') + lam(act, dead))] }),
  retret: (act, dead) => ({ lines: ['mk1 = mk2 q'], f: '(mk1 0)', own: true,
    decls: [fn('mk2', `List Int → (Int → ${CB})`, 'q', (ACTS[act].pre ? ACTS[act].pre + '\n' : '') + `λ_ →\n${ind(lam(act, dead), 4)}`)] }),
  // A callback that answers a callback.
  cbcb: (act, dead) => ({ lines: [...(ACTS[act].pre ? [ACTS[act].pre] : []), `cb2 =\n${ind(lamCurried(act, dead), 4)}`, 'g = λx a → (cb2 x) a'], f: 'g' }),
  // A callback that runs a fold with the callback.
  viafold: (act, dead) => ({ lines: [...local(act, dead), 'g = λx a → List.foldl [ x ] a cb'], f: 'g' }),
  // Recursion: two top-level functions that call each other and run the callback, a local function that
  // calls itself, one that hands itself to a fold, and two local functions that call each other.
  mutual: (act, dead) => ({ lines: [...local(act, dead), 'g = λ_ a → ping cb 1 a'], f: 'g', uses: ['ping', 'pong'] }),
  selfrec: (act, dead) => ({ lines: [...local(act, dead), 'loop m a = if m == 0 then a else loop (m - 1) (cb m a)', 'g = λ_ a → loop 2 a'], f: 'g' }),
  selfpass: (act, dead) => ({ lines: [...local(act, dead), 'walk d a = if d == 0 then cb d a else List.foldl [ d - 1 ] a walk', 'g = λ_ a → walk 2 a'], f: 'g' }),
  later: (act, dead) => ({ lines: [...local(act, dead), 'la m a = if m == 0 then a else lb (m - 1) a', 'lb m a = la m (cb m a)', 'g = λ_ a → la 2 a'], f: 'g' }),
};

// ---------------------------------------------------------------------------------------------
// Runners: how the carried function `f` is run on the shared list `s`. `lol`: the result is a list of lists.
const RUNNERS = {
  call1: (f) => ({ lines: [`f0 = ${f}`, 'res = f0 1 s'] }),
  call2: (f) => ({ lines: [`f0 = ${f}`, 'res = f0 2 (f0 1 s)'] }),
  // Two runs on the same list: the second run reads what the first wrote.
  twice: (f) => ({ lines: [`f0 = ${f}`, 'r1 = f0 1 s', 'res = f0 2 s', 'say ("r1 " ++ show r1)'] }),
  foldl: (f) => ({ lines: [`res = List.foldl [ 1, 2 ] s ${f}`] }),
  ufold: (f) => ({ lines: [`res = ufold [ 1, 2 ] s ${f}`], uses: ['ufold'] }),
  nest: (f) => ({ lines: [`res =\n    List.foldl [ 1, 2 ] s λy a0 →\n        List.foldl [ y ] a0 ${f}`] }),
  mapl: (f) => ({ lines: [`f0 = ${f}`, 'res = List.map [ s, [ 6 ] ] λel → f0 1 el'], lol: true }),
};

function gen(carrier, runner, act, mode) {
  const dead = mode === 'dead';
  const A = ACTS[act];
  const C = CARRIERS[carrier](act, dead);
  const R = RUNNERS[runner](C.f);
  const uses = new Set([...(C.uses || []), ...(R.uses || [])]);
  const lines = ['k = [ n ]', 's = k', 'q = [ 7 ]', ...C.lines, ...R.lines];
  const sh = R.lol ? 'shows' : 'show';
  if (A.edit) {
    lines.push(`res2 = List.push res ${R.lol ? '[ 5 ]' : '5'}`, `say ("res " ++ ${sh} res2)`);
  } else lines.push(`say ("res " ++ ${sh} res)`);
  if (!dead) {
    lines.push('say ("s " ++ show s)');
    if (A.cap) lines.push('say ("q " ++ show q)');
  }
  lines.push('⊤');
  return [
    'import Io\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport Ref exposing (Ref)\nimport String\nimport Task\n',
    fn('say', 'String → ⊤', 'line', 'Debug.log line ⊤'),
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('shows', 'List (List Int) → String', 'ls', 'String.join (List.map ls show) ";"'),
    ...[...uses].sort().map((u) => H[u]),
    ...(C.decls || []),
    fn('scenario', 'Int → ⊤', 'n', lines.join('\n')),
    'main : Program\nmain =\n    Io.run λ⊤ →\n        scenario 0\n        Io.sleep 1\n        Node.done\n',
  ].join('\n\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const carrier of Object.keys(CARRIERS)) for (const runner of Object.keys(RUNNERS)) for (const act of Object.keys(ACTS))
  for (const mode of ['live', 'dead']) {
    const name = `${carrier}.${runner}.${act}.${mode}`;
    if (filter && !name.includes(filter)) continue;
    const d = path.join(out, name);
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'Main.beni'), gen(carrier, runner, act, mode));
    list.push(path.resolve(d));
  }
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
