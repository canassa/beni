// callbacks-keep.mjs <outdir> [filter]: a generator for callbacks that keep what they are handed.
// A frame hands a fresh value to a function value its caller gives (a label), then edits that value
// in place. The caller's code keeps what it is handed (a task, a cell, a closure, a view) and reads
// it later. Programs are `<depth>.<shape>-<edit>.<keep>.<korigin>/Main.beni`; `keep` = `none` is the
// dead twin (the code keeps nothing; refusing it is a precision loss). See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/callbacks-keep.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const fn = (name, sig, params, body) => `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`;

const SH = {
  list: { T: 'List Int', PT: '(List Int)', lit: '[ 0 ]', str: 'show v', part: (o) => o, sp: 'show',
    edits: { push: (o) => `List.push ${o} 2`, set: (o) => `List.set ${o} 0 2`, upd: (o) => `List.update ${o} 0 λi → i + 2` } },
  lol: { T: 'List (List Int)', PT: '(List (List Int))', lit: '[ [ 0 ] ]', str: 'shows v', part: (o) => o, sp: 'shows',
    edits: { in: (o) => `List.update ${o} 0 λm → List.push m 2`, out: (o) => `List.push ${o} [ 2 ]` } },
  rec: { T: '{ l : List Int }', PT: '{ l : List Int }', lit: '{ l = [ 0 ] }', str: 'show v.l', part: (o) => `${o}.l`, sp: 'show',
    edits: { push: (o) => `{ ${o} | l = List.push ${o}.l 2 }` } },
};

// What the caller's code does with what it is handed. `cap`: it captures the cell `r`.
const KEEPS = {
  soon: { body: (sh) => `_ = Task.soon λ⊤ → say ("k " ++ str v)\n⊤` },
  spawn: { body: (sh) => `_ = Task.spawn λ⊤ → say ("k " ++ str v)\n⊤` },
  view: { body: (sh) => `w = List.drop (${sh.part('v')}) 0\n_ = Task.soon λ⊤ → say ("k " ++ ${sh.sp} w)\n⊤` },
  ref: { cap: true, rT: (sh) => `Ref ${sh.PT}`, rInit: (sh) => `Ref.make ${sh.lit.includes(' ') ? `(${sh.lit})` : sh.lit}`, body: () => 'Ref.set r v', read: 'say ("r " ++ str (Ref.get r))' },
  clos: { cap: true, rT: () => 'Ref (⊤ → String)', rInit: () => 'Ref.make λ⊤ → "-"', body: () => 'Ref.set r λ⊤ → str v', read: 'f = Ref.get r\nsay ("r " ++ f ⊤)' },
  none: { body: () => '⊤' },
};
// Where the code comes from at the top (main).
const KORIGINS = ['top', 'lam', 'part', 'gen'];

// How deep the write is below the frame whose caller knows the code.
// d0: scenario hands it to g and edits it; d1: a callee `twice` does, scenario passes g on;
// d2: two middles; fold: a List.foldl lambda hands the accumulator to g, then the next run edits it;
// map: a List.map lambda hands the element to g, then edits it; ret: g is called on a value the frame
// then returns and its caller edits.
const DEPTHS = ['d0', 'd1', 'd2', 'fold', 'map', 'after'];

function gen(depth, shName, edit, keep, ko) {
  const sh = SH[shName], K = KEEPS[keep];
  if (ko === 'part' && !K.cap) return null;
  const E = sh.edits[edit];
  const GT = `(${sh.PT} → ⊤)`;
  const decls = [];
  let scen;
  if (depth === 'd0') scen = `b = ${sh.lit}\ng b\nsay ("res " ++ str (${E('b')}))`;
  else if (depth === 'd1' || depth === 'd2') {
    decls.push(fn('twice', `${GT}, ${sh.T} → ${sh.T}`, 'g a', `g a\n${E('a')}`));
    if (depth === 'd2') decls.push(fn('mid', `${GT}, ${sh.T} → ${sh.T}`, 'g a', 'twice g a'));
    scen = `say ("res " ++ str (${depth === 'd1' ? 'twice' : 'mid'} g ${sh.lit.includes(' ') ? `(${sh.lit})` : sh.lit}))`;
  } else if (depth === 'fold') {
    scen = `res =\n    List.foldl [ 1, 2 ] ${sh.lit.includes(' ') ? `(${sh.lit})` : sh.lit} λ_ a →\n        b = ${E('a')}\n        g b\n        b\nsay ("res " ++ str res)`;
  } else if (depth === 'map') {
    scen = `res =\n    List.map [ ${sh.lit}, ${sh.lit} ] λa →\n        g a\n        ${E('a')}\nsay ("res " ++ String.join (List.map res str) ";")`;
  } else if (depth === 'after') {
    decls.push(fn('hand', `${GT}, ${sh.T} → ${sh.T}`, 'g a', 'g a\na'));
    scen = `b = hand g ${sh.lit.includes(' ') ? `(${sh.lit})` : sh.lit}\nsay ("res " ++ str (${E('b')}))`;
  }
  decls.push(fn('scenario', `${GT} → ⊤`, 'g', scen + '\n⊤'));
  // The code at main.
  let mainLines = [];
  let arg;
  const kbody = K.body(sh);
  if (K.cap) mainLines.push(`r = ${K.rInit(sh)}`);
  if (ko === 'top') {
    if (K.cap) { decls.push(fn('keep', `${K.rT(sh)}, ${sh.PT} → ⊤`, 'r v', kbody)); arg = 'λv → keep r v'; }
    else { decls.push(fn('keep', `${sh.PT} → ⊤`, 'v', kbody)); arg = 'keep'; }
  } else if (ko === 'lam') {
    mainLines.push(`k =\n    λv →\n${ind(kbody, 8)}`); arg = 'k';
  } else if (ko === 'part') {
    decls.push(fn('keep', `${K.rT(sh)}, ${sh.PT} → ⊤`, 'r v', kbody)); arg = '(keep r _)';
  } else if (ko === 'gen') {
    if (K.cap) { decls.push(fn('keep', `${K.rT(sh)}, ${sh.PT} → ⊤`, 'r v', kbody)); arg = '(ident λv → keep r v)'; }
    else { decls.push(fn('keep', `${sh.PT} → ⊤`, 'v', kbody)); arg = '(ident keep)'; }
  }
  mainLines.push(`scenario ${arg}`);
  if (K.read) mainLines.push(K.read);
  mainLines.push('Io.sleep 1', 'Node.done');
  const src = [
    'import Io\nimport List\nimport Node exposing (Program)\nimport Ref exposing (Ref)\nimport String\nimport Task\n',
    fn('say', 'String → ⊤', 'line', 'Debug.log line ⊤'),
    fn('show', 'List Int → String', 'l', 'String.join (List.map l String.fromInt) ","'),
    fn('shows', 'List (List Int) → String', 'ls', 'String.join (List.map ls show) ";"'),
    fn('str', `${sh.PT} → String`, 'v', sh.str),
    fn('ident', 'a → a', 'f', 'f'),
    ...decls,
    `main : Program\nmain =\n    Io.run λ⊤ →\n${ind(mainLines.join('\n'), 8)}\n`,
  ].join('\n\n');
  return src;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const depth of DEPTHS) for (const [shName, sh] of Object.entries(SH)) for (const edit of Object.keys(sh.edits))
  for (const keep of Object.keys(KEEPS)) for (const ko of KORIGINS) {
    const name = `${depth}.${shName}-${edit}.${keep}.${ko}`;
    if (filter && !name.includes(filter)) continue;
    const src = gen(depth, shName, edit, keep, ko);
    if (!src) continue;
    const d = path.join(out, name);
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'Main.beni'), src);
    list.push(path.resolve(d));
  }
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
