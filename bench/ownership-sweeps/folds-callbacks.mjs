// folds-callbacks.mjs <outdir> [filter]: a systematic (not random) generator for folds and callbacks.
// Enumerates kind × target × shape.edit × action × origin × mode, one program per directory
// `<outdir>/<kind>.<target>.<shape>-<edit>.<action>.<origin>.<mode>/Main.beni`, and writes
// `<outdir>/LIST`. Every program prints the call's result and, by mode, the shared value `s`
// and whatever the callback kept: an in-place edit of a shared list changes a printed line, so the
// oracle's DIFF is a wrong answer even where the sanitiser sees nothing. See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/folds-callbacks.mjs <outdir> [filter]'); process.exit(2); }

const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;
const multi = (s) => s.includes('\n');
// `name = e`, with e on its own lines when it has several.
const bind = (name, e) => (multi(e) ? `${name} =\n${ind(e, 4)}` : `${name} = ${e}`);

// ---------------------------------------------------------------------------------------------
// Shapes: the value the callback edits. `T` its type, `wrap(e)` builds one around the list e,
// `edits[name](o, x)` an expression of type T with o's list edited (in place when v2 allows),
// `part(o)` its main list (a view is taken of it) and `showPart` that list's printer, `str` the
// helper that prints a T (defined in `helpers`).
const SH = {
  list: {
    T: 'List Int', wrap: (e) => e,
    edits: { push: (o, x) => `List.push ${o} ${x}`, set: (o, x) => `List.set ${o} 0 ${x}`, upd: (o, x) => `List.update ${o} 0 λi → i + ${x}` },
    part: (o) => o, showPart: 'show', helpers: fn('str', 'List Int → String', 'v', 'show v'),
  },
  lol: {
    T: 'List (List Int)', wrap: (e) => `[ ${e} ]`,
    edits: {
      out: (o, x) => `List.push ${o} [ ${x} ]`, in: (o, x) => `List.update ${o} 0 λm → List.push m ${x}`,
      set: (o, x) => `List.set ${o} 0 [ ${x} ]`,
    },
    part: (o) => o, showPart: 'shows', helpers: fn('str', 'List (List Int) → String', 'v', 'shows v'),
  },
  tup: {
    T: 'List Int × Int', wrap: (e) => `( ${e}, 0 )`,
    edits: { push: (o, x) => `case ${o} of\n    ( l, n ) →\n        ( List.push l ${x}, n + 1 )` },
    part: (o) => `fstL ${o}`, showPart: 'show',
    helpers: fn('str', 'List Int × Int → String', 'v', 'case v of\n    ( l, n ) →\n        show l ++ "/" ++ String.fromInt n') + '\n' +
      fn('fstL', 'List Int × Int → List Int', 'v', 'case v of\n    ( l, _ ) →\n        l'),
  },
  rec: {
    T: '{ l : List Int, n : Int }', wrap: (e) => `{ l = ${e}, n = 0 }`,
    edits: { push: (o, x) => `{ ${o} | l = List.push ${o}.l ${x} }`, upd: (o, x) => `{ ${o} | l = List.update ${o}.l 0 λi → i + ${x} }` },
    part: (o) => `${o}.l`, showPart: 'show', helpers: fn('str', '{ l : List Int, n : Int } → String', 'v', 'show v.l'),
  },
  may: {
    T: 'Maybe (List Int)', wrap: (e) => `Just ${e}`,
    edits: { push: (o, x) => `case ${o} of\n    Just l →\n        Just (List.push l ${x})\n\n    Nothing →\n        Nothing` },
    part: (o) => `Maybe.withDefault ${o} []`, showPart: 'show',
    helpers: fn('str', 'Maybe (List Int) → String', 'v', 'case v of\n    Just l →\n        show l\n\n    Nothing →\n        "-"'),
  },
  box: {
    T: 'Box', wrap: (e) => `Box ${e}`, decl: 'type Box\n    = Box (List Int)\n',
    edits: { push: (o, x) => `case ${o} of\n    Box l →\n        Box (List.push l ${x})` },
    part: (o) => `unbox ${o}`, showPart: 'show',
    helpers: fn('str', 'Box → String', 'v', 'show (unbox v)') + '\n' + fn('unbox', 'Box → List Int', 'v', 'case v of\n    Box l →\n        l'),
  },
  clo: {
    T: '⊤ → List Int', wrap: (e) => `λ⊤ → ${e}`,
    edits: { push: (o, x) => `l = List.push (${o} ⊤) ${x}\nλ⊤ → l` },
    part: (o) => `${o} ⊤`, showPart: 'show', helpers: fn('str', '(⊤ → List Int) → String', 'v', 'show (v ⊤)'),
  },
};

// ---------------------------------------------------------------------------------------------
// Kinds. `fam`: F (a fold: callback (x, acc → acc), or (key, x, acc → acc) for a Dict) or
// M (one call per element: the "accumulator" is the element). `targets`: F folds may edit the
// accumulator (`acc`) or the element (`elem`, folding a list of T into a list of results).
const KINDS = {
  foldl: { fam: 'F', targets: ['acc', 'elem'], call: (xs, init, cb) => `List.foldl ${xs} ${init} ${cb}` },
  foldr: { fam: 'F', targets: ['acc', 'elem'], call: (xs, init, cb) => `List.foldr ${xs} ${init} ${cb}` },
  ufold: { fam: 'F', targets: ['acc', 'elem'], call: (xs, init, cb) => `ufold ${xs} ${init} ${cb}`, uses: ['ufold'] },
  ufoldr: { fam: 'F', targets: ['acc'], call: (xs, init, cb) => `ufoldr ${xs} ${init} ${cb}`, uses: ['ufoldr'] },
  loop: { fam: 'F', targets: ['acc', 'elem'], loop: true },
  dictl: { fam: 'F', targets: ['acc'], dict: true, call: (xs, init, cb) => `Dict.foldl (Dict.fromList [ ( 1, 1 ), ( 2, 2 ) ]) ${init} ${cb}` },
  dictr: { fam: 'F', targets: ['acc'], dict: true, call: (xs, init, cb) => `Dict.foldr (Dict.fromList [ ( 1, 1 ), ( 2, 2 ) ]) ${init} ${cb}` },
  nest: { fam: 'F', targets: ['acc'], call: (xs, init, cb) => `List.foldl ${xs} ${init} λy a0 →\n    List.foldl [ y ] a0 ${cb.split('\n').map((l, i) => (i && l ? '    ' + l : l)).join('\n')}` },
  lmap: { fam: 'M', res: 'list', call: (xs, cb) => `List.map ${xs} ${cb}` },
  imap: { fam: 'M', res: 'list', idx: true, call: (xs, cb) => `List.indexedMap ${xs} ${cb}` },
  filter: { fam: 'M', res: 'list', bool: true, call: (xs, cb) => `List.filter ${xs} ${cb}` },
  mmap: { fam: 'M', res: 'maybe', call: (xs, cb) => `Maybe.map (Just ${xs}) ${cb}` },
  mthen: { fam: 'M', res: 'maybe', just: true, call: (xs, cb) => `Maybe.andThen (Just ${xs}) ${cb}` },
};

// Actions: what the callback does with the edited value `b` besides answering it. `caps`: what
// it captures (r: a Ref, g: a function). `keep`: it keeps `b` past its run (a `kept` mode exists).
const ACTIONS = {
  plain: { caps: [] },
  soon: { caps: [], keep: true },
  spawn: { caps: [], keep: true },
  drop: { caps: [], keep: true },
  rest: { caps: [], keep: true },
  ref: { caps: ['r'], keep: true },
  clos: { caps: ['r'], keep: true },
  give: { caps: ['g'], keep: true, param: true },
  givel: { caps: ['g'], keep: true },
  ans: { caps: [], keep: true },
};

const ORIGINS = ['lam', 'loc', 'top', 'ret', 'gen', 'comp', 'part', 'dir'];
const MODES = ['live', 'kept', 'dead'];

// The lines of an action on `b` (type T) in mode `mode`.
function actionLines(sh, action, mode) {
  const dead = mode === 'dead';
  const tick = '_ = Task.soon λ⊤ → say "tick"';
  switch (action) {
    case 'plain': case 'ans': case 'give': case 'givel': return action.startsWith('give') ? ['g b'] : [];
    case 'soon': return [dead ? tick : '_ = Task.soon λ⊤ → say ("soon " ++ str b)'];
    case 'spawn': return [dead ? '_ = Task.spawn λ⊤ → say "tick"' : '_ = Task.spawn λ⊤ → say ("spawn " ++ str b)'];
    case 'drop': return dead ? [tick] : [`v = List.drop (${sh.part('b')}) 1`, `_ = Task.soon λ⊤ → say ("drop " ++ ${sh.showPart} v)`];
    case 'rest': return dead ? [tick] : [bind('_', `case ${sh.part('b')} of\n    [ _, …more ] →\n        Task.soon λ⊤ → say ("rest " ++ ${sh.showPart} more)\n\n    [] →\n        Task.soon λ⊤ → ⊤`)];
    case 'ref': return ['Ref.set r b'];
    case 'clos': return ['Ref.set r λ⊤ → str b'];
  }
  throw new Error(action);
}

// The body of the callback: edit `obj` with `x`, run the action, answer.
// F/acc: obj = a (or a1 from a pair for ans), answer b (or ( b, a1 )).
// F/elem: obj = x, x for the edit is 1, answer List.push a RB.
// M: obj = a, answer RB / Just RB / a Bool.
function body(c, sh, edit, action, mode) {
  const lines = [];
  let obj, xv, answer;
  const rb = (o) => (action === 'ans' ? `( b, ${o} )` : 'b');
  if (c.fam === 'F' && c.target === 'acc') {
    obj = action === 'ans' ? 'a1' : 'a'; xv = 'x'; answer = rb(obj);
  } else if (c.fam === 'F') {
    obj = 'x'; xv = '1'; answer = `List.push a ${rb('x')}`;
  } else {
    obj = 'a'; xv = c.kind.idx ? 'x' : '1';
    answer = c.kind.bool ? `List.length (${sh.part('b')}) > 0` : c.kind.just ? `Just ${rb('a')}` : rb('a');
    if (answer.startsWith('Just (')) answer = `Just ${rb('a')}`;
  }
  lines.push(bind('b', sh.edits[edit](obj, xv)));
  lines.push(...actionLines(sh, action, mode));
  lines.push(answer);
  let txt = lines.join('\n');
  if (c.fam === 'F' && c.target === 'acc' && action === 'ans') txt = `case a of\n    ( a1, _ ) →\n${ind(txt, 8)}`;
  return txt;
}

function gen(kindName, target, shapeName, edit, action, origin, mode) {
  const kind = KINDS[kindName], sh = SH[shapeName], act = ACTIONS[action];
  const c = { fam: kind.fam, target, kind };
  const T = sh.T;
  const PT = /[ ]/.test(T) && !T.startsWith('{') ? `(${T})` : T;
  const R = action === 'ans' ? `${PT} × ${PT}` : T;
  const PR = R === T ? PT : `(${R})`; // what one run answers per element (or the acc)
  // Applicability.
  if (mode === 'kept' && !act.keep) return null;
  if (action === 'ans' && kind.bool) return null;
  const nargs = kind.fam === 'M' ? (kind.idx ? 2 : 1) : kind.dict ? 3 : 2;
  if (kind.loop ? origin !== 'dir' : origin === 'dir') return null;
  if (origin === 'part' && nargs !== 1) return null;
  if (origin === 'comp' && kind.dict) return null;
  const caps = act.caps;
  if (origin === 'top' && caps.length) return null;
  if (kind.idx && origin === 'part') return null;

  const uses = new Set(kind.uses || []);
  // Types.
  const X = kind.fam === 'F' && target === 'elem' ? T : 'Int';
  let A; // the accumulator (F) or the result element (M)
  if (kind.fam === 'F') A = target === 'acc' ? R : `List ${PR}`;
  const capT = { r: action === 'clos' ? 'Ref (⊤ → String)' : `Ref ${PT}`, g: `(${PT} → ⊤)` };
  const PA = A && (A.includes('→') || A.includes('×')) && !A.startsWith('List') ? `(${A})` : A;
  const PX = X.includes('→') ? `(${X})` : X;
  const cbParamsT = kind.fam === 'M' ? [kind.idx ? ['x', 'Int'] : null, ['a', PT]].filter(Boolean)
    : kind.dict ? [['_', 'Int'], ['x', 'Int'], ['a', PA]] : [['x', PX], ['a', PA]];
  const cbRes = kind.fam === 'F' ? PA : kind.bool ? 'Bool' : kind.just ? `Maybe ${PR}` : PR;
  const cbT = `${cbParamsT.map((p) => p[1]).join(', ')} → ${cbRes}`;
  const cbPs = cbParamsT.map((p) => p[0]).join(' ');
  const B = body(c, sh, edit, action, mode);
  const lam = `λ${cbPs} →\n${ind(B, 4)}`;

  const decls = [];
  // The callback expression at the call, by origin.
  let cb;
  const capArgs = caps.length ? caps.join(' ') : '0';
  const capPs = caps.length ? caps.join(' ') : '_';
  const capTs = caps.length ? caps.map((n) => capT[n]) : ['Int'];
  const local = [];
  switch (origin) {
    case 'lam': cb = lam; break;
    case 'loc': local.push(bind('cb', lam)); cb = 'cb'; break;
    case 'top':
      decls.push(fn('step', cbT, cbPs.replace(/_/g, 'kk'), B)); cb = 'step'; break;
    case 'ret':
      decls.push(fn('stepc', `${capTs.join(', ')} → (${cbT})`, capPs, lam)); cb = `(stepc ${capArgs})`; break;
    case 'gen': local.push(bind('cb', lam)); cb = '(ident cb)'; uses.add('ident'); break;
    case 'comp':
      local.push(bind('cb', lam));
      cb = nargs === 1 ? '(comp1 cb λv → v)' : '(comp cb λ_ v → v)'; uses.add(nargs === 1 ? 'comp1' : 'comp'); break;
    case 'part':
      decls.push(fn('stepp', `${capTs.join(', ')}, ${PT} → ${cbRes}`, `${capPs} a`, B)); cb = `(stepp ${capArgs} _)`; break;
    case 'dir': break;
  }

  // The scenario.
  const live = mode === 'live';
  const lines = [];
  let init;
  if (mode === 'kept') init = sh.wrap('[ 0 ]');
  else { lines.push('k = [ 0 ]', bind('s', sh.wrap('k'))); init = 's'; }
  if (init.includes(' ')) init = `(${init})`;
  if (caps.includes('r')) lines.push(action === 'clos' ? 'r = Ref.make λ⊤ → "-"' : `r = Ref.make (${sh.wrap('[ 9 ]')})`);
  if (action === 'givel') lines.push(mode === 'dead' ? 'g = λ_ → ⊤' : bind('g', `λv →\n    _ = Task.soon λ⊤ → say ("g " ++ str v)\n    ⊤`));
  lines.push(...local);
  let call, resStr;
  // A dead `ans` prints only the first half: the second is the kept earlier value.
  const strR = action === 'ans' ? (mode === 'dead' ? 'strP1' : 'strP') : 'str';
  if (action === 'ans') uses.add(strR);
  if (kind.fam === 'F') {
    let xs, finit;
    if (target === 'acc') {
      xs = '[ 1, 2 ]';
      finit = action === 'ans' ? `( ${init.replace(/^\((.*)\)$/, '$1')}, ${sh.wrap('[ 5 ]')} )` : init;
    } else { xs = `[ ${init.replace(/^\((.*)\)$/, '$1')}, ${sh.wrap('[ 6 ]')} ]`; finit = '[]'; }
    if (kind.loop) {
      const lc = caps.length ? caps.join(' ') + ' ' : '';
      const lcT = caps.map((n) => capT[n] + ', ').join('');
      call = `loop ${lc}${xs} ${finit}`;
      decls.push(fn('loop', `${lcT}List ${X === 'Int' ? 'Int' : `(${X})`}, ${PA} → ${PA}`, `${lc}xs a`,
        `case xs of\n    [] →\n        a\n\n    [ x, …rest ] →\n        loop ${lc}rest (step ${lc}x a)`));
      decls.push(fn('step', `${lcT}${PX}, ${PA} → ${PA}`, `${lc}x a`, B));
    } else call = kind.call(xs, finit, cb);
    resStr = target === 'acc' ? `${strR} res` : `String.join (List.map res ${strR}) ";"`;
  } else {
    const xs = kind.res === 'maybe' ? init : `[ ${init.replace(/^\((.*)\)$/, '$1')}, ${sh.wrap('[ 6 ]')} ]`;
    call = kind.call(xs, cb);
    const rT = kind.bool ? 'str' : strR;
    resStr = kind.res === 'list' ? `String.join (List.map res ${rT}) ";"` : null;
  }
  lines.push(bind('res', call));
  if (resStr) lines.push(`say ("res " ++ ${resStr})`);
  else lines.push(bind('rs', `case res of\n    Just w →\n        ${strR} w\n\n    Nothing →\n        "-"`), 'say ("res " ++ rs)');
  if (live) lines.push('say ("s " ++ str s)');
  if (mode !== 'dead' && action === 'ref') lines.push('say ("ref " ++ str (Ref.get r))');
  if (mode !== 'dead' && action === 'clos') lines.push('f = Ref.get r', 'say ("clos " ++ f ⊤)');
  lines.push('⊤');
  const scen = act.param ? fn('scenario', `(${PT} → ⊤) → ⊤`, 'g', lines.join('\n')) : fn('scenario', '⊤ → ⊤', '⊤', lines.join('\n'));
  const mainArg = act.param ? (mode === 'dead' ? 'nokeep' : 'keep') : '⊤';
  if (act.param) uses.add(mode === 'dead' ? 'nokeep' : 'keep');

  const H = {
    ident: fn('ident', 'a → a', 'f', 'f'),
    comp: fn('comp', '(x, a → b), (x, b → c) → (x, a → c)', 'f g', 'λx a → g x (f x a)'),
    comp1: fn('comp1', '(a → b), (b → c) → (a → c)', 'f g', 'λa → g (f a)'),
    ufold: fn('ufold', 'List x, a, (x, a → a) → a', 'xs acc f', 'case xs of\n    [] →\n        acc\n\n    [ x, …rest ] →\n        ufold rest (f x acc) f'),
    ufoldr: fn('ufoldr', 'List x, a, (x, a → a) → a', 'xs acc f', 'case xs of\n    [] →\n        acc\n\n    [ x, …rest ] →\n        f x (ufoldr rest acc f)'),
    strP: fn('strP', `${PT} × ${PT} → String`, 'p', 'case p of\n    ( u, w ) →\n        str u ++ "|" ++ str w'),
    strP1: fn('strP1', `${PT} × ${PT} → String`, 'p', 'case p of\n    ( u, _ ) →\n        str u'),
    keep: fn('keep', `${PT} → ⊤`, 'v', '_ = Task.soon λ⊤ → say ("g " ++ str v)\n⊤'),
    nokeep: fn('nokeep', `${PT} → ⊤`, '_', '⊤'),
  };
  const src = [
    'import Dict\nimport Io\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport Ref exposing (Ref)\nimport String\nimport Task\n',
    ...(sh.decl ? [sh.decl] : []),
    fn('say', 'String → ⊤', 'line', 'Debug.log line ⊤'),
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('shows', 'List (List Int) → String', 'ls', 'String.join (List.map ls show) ";"'),
    sh.helpers,
    ...[...uses].sort().map((u) => H[u]),
    ...decls,
    scen,
    fn('main', 'Program', '', `Io.run λ⊤ →\n    scenario ${mainArg}\n    Io.sleep 1\n    Node.done`).replace('main  =', 'main ='),
  ].join('\n\n');
  return src;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const kindName of Object.keys(KINDS)) {
  const kind = KINDS[kindName];
  for (const target of kind.targets || ['-']) {
    for (const [shapeName, sh] of Object.entries(SH)) {
      for (const edit of Object.keys(sh.edits)) {
        for (const action of Object.keys(ACTIONS)) {
          for (const origin of ORIGINS) {
            for (const mode of MODES) {
              const name = `${kindName}.${target}.${shapeName}-${edit}.${action}.${origin}.${mode}`;
              if (filter && !name.includes(filter)) continue;
              const src = gen(kindName, target, shapeName, edit, action, origin, mode);
              if (!src) continue;
              const d = path.join(out, name);
              fs.mkdirSync(d, { recursive: true });
              fs.writeFileSync(path.join(d, 'Main.beni'), src);
              list.push(path.resolve(d));
            }
          }
        }
      }
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
