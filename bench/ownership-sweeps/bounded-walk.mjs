// bounded-walk.mjs: shapes that make a walk of the ownership checker revisit shared structure, each at a
// size where a walk that follows every path does not end (research report 127). A checker that is bounded
// by design ends each of them in well under a second; the sanitiser judges what it accepts.
//
//   node bench/ownership-sweeps/bounded-walk.mjs <outdir> [filter]
//
// Families (each with a `live` twin that reads the written list after the write, and a `dead` one):
//
// - `dag.<k>.<holder>`: a DAG of local closures, `k` per level, each capturing the `k` of the level below
//   (research report 126 §3); the last is called directly, through a `Ref`, or handed to `List.map`.
// - `dagw.<k>`: the same, and the leaf closure writes its parameter.
// - `climb`: each closure hands its own parameter, unchanged, to one of three captured closures, chosen by
//   `if`; the leaf writes it, so each judgment reads the whole chain of holders above it.
// - `fresh`: each closure makes a new list and hands it on through the three closures it captured; the
//   leaf keeps what it is handed in a `Ref` (a cell named by the path that made it).
// - `answers`: each closure answers one of three captured closures' answers, chosen by `if`; the caller
//   writes the answer.
// - `helpers`: the same DAG as `dag`, of top-level functions.
// - `record`: each level is a record of three functions, each calling the three of the level below.
// - `refs`: each level keeps its function in a `Ref` and calls the three of the level below out of theirs.
// - `group.local` and `group.top`: a ring of mutually recursive functions that hand a list on, local and
//   top-level, one of which writes it.
// - `deeptype`: a list under `Just` nested many times, written through a pattern.
//
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/bounded-walk.mjs <outdir> [filter]'); process.exit(2); }
const L = Number(process.env.BOUNDED_LEVELS ?? 24);
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const list = [];
function emit(name, src) {
  if (!name.includes(filter)) return;
  const dir = path.join(out, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'Main.beni'), src);
  list.push(path.resolve(dir));
}
const HDR = `import List
import Node exposing (Program)
import Ref
import String


show : List Int → String
show l = String.join (List.map l String.fromInt) ","`;
const main = (decls, body) => [HDR, decls, `go : Int → String\ngo n =\n${ind(body, 4)}\n`, 'main : Program\nmain = Node.print (go 1)\n'].filter((x) => x !== '').join('\n\n\n');
const names = 'abcdefgh';
// The closures of level i: `k` names, each calling the k of the level below in a rotated order.
const dagLines = (k, leaf, levels = L) => {
  const lines = [];
  for (let j = 0; j < k; j++) lines.push(`${names[j]}0 = ${leaf(j)}`);
  for (let i = 1; i <= levels; i++) {
    for (let j = 0; j < k; j++) {
      let e = 'l';
      for (let r = 0; r < k; r++) e = `${names[(j + r) % k]}${i - 1} (${e})`;
      lines.push(`${names[j]}${i} = λl → ${e.replace(/ \(l\)$/, ' l')}`);
    }
  }
  return lines;
};
const leaves = ['λl → List.take l n', 'λl → List.reverse l', 'λl → List.drop l 1', 'λl → List.take l 3'];
const tail = (mode) => (mode === 'live' ? ' ++ show xs' : '');

// dag: report 126's shape.
for (const k of [2, 3]) {
  for (const holder of ['call', 'ref', 'map']) {
    for (const mode of ['live', 'dead']) {
      const lines = dagLines(k, (j) => leaves[j]);
      const f = `a${L}`;
      const use = holder === 'call' ? `${f} [ 4, 5 ]` : holder === 'ref' ? `(Ref.get (Ref.make ${f})) [ 4, 5 ]` : `List.concat (List.map [ [ 4 ], [ 5 ] ] ${f})`;
      lines.push('xs = [ n, 2 ]', 'ys = List.push xs 3', `show ys ++ show (${use})${tail(mode)}`);
      emit(`dag.${k}.${holder}.${mode}`, main('', lines.join('\n')));
    }
  }
}

// dagw: the leaf writes its parameter.
for (const k of [2, 3]) {
  for (const mode of ['live', 'dead']) {
    const lines = dagLines(k, (j) => (j === 0 ? 'λl → List.push l n' : leaves[j]));
    lines.push('xs = [ n, 2 ]', 'ys = List.push xs 3', `show ys ++ show (a${L} [ 4, 5 ])${tail(mode)}`);
    emit(`dagw.${k}.${mode}`, main('', lines.join('\n')));
  }
}

// climb: each closure hands its parameter on, unchanged, to one of three captured closures.
for (const mode of ['live', 'dead']) {
  const lines = ['a0 = λl → List.push l n', 'b0 = λl → List.push l 2', 'c0 = λl → List.push l 3'];
  for (let i = 1; i <= L; i++) {
    for (let j = 0; j < 3; j++) {
      const [x, y, z] = [0, 1, 2].map((r) => `${names[(j + r) % 3]}${i - 1}`);
      lines.push(`${names[j]}${i} = λl → if List.length l > ${i} then ${x} l else if List.length l > ${j} then ${y} l else ${z} l`);
    }
  }
  const arg = mode === 'live' ? 'xs' : 'List.copy xs';
  lines.push('xs = [ n, 2 ]', `ys = a${L} (${arg})`, 'show ys ++ show xs');
  emit(`climb.${mode}`, main('', lines.join('\n')));
}

// fresh: each closure hands a new list on through the three closures it captured; the leaf keeps it.
for (const mode of ['live', 'dead']) {
  const keep = mode === 'live' ? 'Ref.set cell l' : 'Ref.set cell (List.copy l)';
  const lines = ['cell = Ref.make [ 0 ]', `a0 = λl →\n    ${keep}\n    l`, 'b0 = λl → List.reverse l', 'c0 = λl → List.take l 1'];
  for (let i = 1; i <= L; i++) {
    for (let j = 0; j < 3; j++) {
      const [x, y, z] = [0, 1, 2].map((r) => `${names[(j + r) % 3]}${i - 1}`);
      lines.push(`${names[j]}${i} = λl → ${x} (${y} (${z} [ ${i}, ${j} ]))`);
    }
  }
  const last = mode === 'live' ? 'w = List.push v 9\nshow w ++ show (Ref.get cell)' : 'show (List.push v 9)';
  lines.push(`v = a${L} [ n ]`, last);
  emit(`fresh.${mode}`, main('', lines.join('\n')));
}

// answers: each closure answers one of three captured closures' answers.
for (const mode of ['live', 'dead']) {
  const lines = ['a0 = λl → l', 'b0 = λl → List.reverse l', 'c0 = λl → List.take l 1'];
  for (let i = 1; i <= L; i++) {
    for (let j = 0; j < 3; j++) {
      const [x, y, z] = [0, 1, 2].map((r) => `${names[(j + r) % 3]}${i - 1}`);
      lines.push(`${names[j]}${i} = λl → if List.length l > ${i} then ${x} l else if List.length l > ${j} then ${y} l else ${z} l`);
    }
  }
  lines.push('xs = [ n, 2 ]', `ys = List.push (a${L} xs) 3`, `show ys${tail(mode)}`);
  emit(`answers.${mode}`, main('', lines.join('\n')));
}

// helpers: the DAG of top-level functions.
for (const mode of ['live', 'dead']) {
  const decls = [];
  const sig = 'List Int → List Int';
  for (let j = 0; j < 3; j++) decls.push(`${names[j]}0 : ${sig}\n${names[j]}0 l = ${leaves[j].slice(5).replace(/\bn\b/, '2')}`);
  for (let i = 1; i <= L; i++) {
    for (let j = 0; j < 3; j++) {
      const [x, y, z] = [0, 1, 2].map((r) => `${names[(j + r) % 3]}${i - 1}`);
      decls.push(`${names[j]}${i} : ${sig}\n${names[j]}${i} l = ${x} (${y} (${z} l))`);
    }
  }
  emit(`helpers.${mode}`, main(decls.join('\n\n\n'), ['xs = [ n, 2 ]', 'ys = List.push xs 3', `show ys ++ show (a${L} [ 4, 5 ])${tail(mode)}`].join('\n')));
}

// record: a record of three functions per level.
for (const mode of ['live', 'dead']) {
  const lines = ['r0 = { a = λl → List.take l n, b = λl → List.reverse l, c = λl → List.drop l 1 }'];
  for (let i = 1; i <= L; i++) {
    const p = `r${i - 1}`;
    lines.push(`r${i} = { a = λl → ${p}.a (${p}.b (${p}.c l)), b = λl → ${p}.b (${p}.c (${p}.a l)), c = λl → ${p}.c (${p}.a (${p}.b l)) }`);
  }
  lines.push('xs = [ n, 2 ]', 'ys = List.push xs 3', `show ys ++ show (r${L}.a [ 4, 5 ])${tail(mode)}`);
  emit(`record.${mode}`, main('', lines.join('\n')));
}

// refs: each level keeps its function in a `Ref`.
for (const mode of ['live', 'dead']) {
  const lines = ['ra0 = Ref.make (λl → List.take l n)', 'rb0 = Ref.make (λl → List.reverse l)', 'rc0 = Ref.make (λl → List.drop l 1)'];
  for (let i = 1; i <= L; i++) {
    for (let j = 0; j < 3; j++) {
      const [x, y, z] = [0, 1, 2].map((r) => `(Ref.get r${names[(j + r) % 3]}${i - 1})`);
      lines.push(`r${names[j]}${i} = Ref.make (λl → ${x} (${y} (${z} l)))`);
    }
  }
  lines.push('xs = [ n, 2 ]', 'ys = List.push xs 3', `show ys ++ show ((Ref.get ra${L}) [ 4, 5 ])${tail(mode)}`);
  emit(`refs.${mode}`, main('', lines.join('\n')));
}

// group: a ring of G mutually recursive functions that hand a list on; the last one writes it.
const G = Number(process.env.BOUNDED_GROUP ?? 40);
for (const where of ['local', 'top']) {
  for (const mode of ['live', 'dead']) {
    const fns = [];
    for (let i = 0; i < G; i++) {
      const next = `g${(i + 1) % G}`;
      const body = i === G - 1 ? `if k ≤ 0 then List.push l k else ${next} l (k - 1)` : `if k ≤ 0 then l else ${next} l (k - 1)`;
      fns.push({ name: `g${i}`, body });
    }
    const arg = mode === 'live' ? 'xs' : 'List.copy xs';
    const call = [`xs = [ n, 2 ]`, `ys = g0 (${arg}) ${G * 2}`, 'show ys ++ show xs'];
    if (where === 'local') {
      const lines = fns.map((f) => `${f.name} = λl k → ${f.body}`);
      emit(`group.local.${mode}`, main('', [...lines, ...call].join('\n')));
    } else {
      const decls = fns.map((f) => `${f.name} : List Int, Int → List Int\n${f.name} l k = ${f.body}`);
      emit(`group.top.${mode}`, main(decls.join('\n\n\n'), call.join('\n')));
    }
  }
}

// deeptype: a list under `Just` nested D times, written through a pattern.
const D = Number(process.env.BOUNDED_DEPTH ?? 100);
for (const mode of ['live', 'dead']) {
  let v = 'xs';
  for (let i = 0; i < D; i++) v = `Just (${v})`;
  let pat = 'l';
  for (let i = 0; i < D; i++) pat = `Just (${pat})`;
  const arg = mode === 'live' ? 'xs' : 'List.copy xs';
  const body = ['xs = [ n, 2 ]', `deep = ${v.replace(/xs\)*$/, (m) => m.replace('xs', arg))}`, 'r =', `    case deep of`, `        ${pat} →`, '            List.push l 3', '', '        _ →', '            [ 0 ]', 'show r ++ show xs'];
  emit(`deeptype.${mode}`, main('', body.join('\n')));
}

fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs in ${out}`);
