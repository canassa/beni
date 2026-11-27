// wide-record-writes.mjs: a call that writes many locations of one record argument (#2534, #2535).
//
//   node bench/ownership-sweeps/wide-record-writes.mjs <outdir> [filter]
//
// A callee that pushes onto each list field of a record writes two locations for a field, the slot
// and the list, and each write of the call is tested against each other location of the record
// (kernel §5, test 2). A write passes only the kept reads of the other locations that have an atom
// at a root and entry of it (kernel §8, *A write passes only the kept reads that have an atom at a
// root and entry of it*). The programs vary what the other locations hold, so that the locations
// that a write passes and the locations that it does not are both there:
//   n       the fields of the record: 4 and 64 (in the budget with each pair compared), and 232,
//           245, 260 and 270 (past it then)
//   write   each    each field gets a push onto its own list
//           swap    each field gets a push onto the list of the field after it
//           one     only the first field is written, the others are read
//           half    the first half of the fields get a push; the function only answers the others
//   record  fresh   each field has a list of its own
//           shared  the first two fields hold one list
//           far     the first and the last field hold one list
//           handed  the lists of the fields are lists that the caller keeps
// Each has a dead twin (the caller reads nothing of the old record after) and a live twin (it reads
// a list that it handed, or the shared list, after the call). A live twin that is accepted and
// written in place prints another output than the plain build or traps: `run.mjs` finds both.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
const filter = process.argv[3];
if (!out) {
  console.error('usage: node bench/ownership-sweeps/wide-record-writes.mjs <outdir> [filter]');
  process.exit(2);
}

const sizes = [4, 64, 232, 245, 260, 270];

const writes = {
  each: (n) => Array.from({ length: n }, (_, i) => `f${i} = List.push r.f${i} ${i}`),
  swap: (n) => Array.from({ length: n }, (_, i) => `f${i} = List.push r.f${(i + 1) % n} ${i}`),
  one: () => ['f0 = List.push r.f0 (List.length r.f1)'],
  half: (n) => Array.from({ length: Math.ceil(n / 2) }, (_, i) => `f${i} = List.push r.f${i} ${i}`),
};

// What `main` binds before the call, the record that it hands, and the list that a live twin reads after.
const records = {
  fresh: (n) => ({ pre: [], fields: Array.from({ length: n }, (_, i) => `f${i} = [ ${i} ]`), live: null }),
  shared: (n) => ({ pre: ['xs = [ 7, 8 ]'], fields: Array.from({ length: n }, (_, i) => `f${i} = ${i < 2 ? 'xs' : `[ ${i} ]`}`), live: 'xs' }),
  far: (n) => ({ pre: ['xs = [ 7, 8 ]'], fields: Array.from({ length: n }, (_, i) => `f${i} = ${i === 0 || i === n - 1 ? 'xs' : `[ ${i} ]`}`), live: 'xs' }),
  handed: (n) => ({ pre: ['xs = [ 7, 8 ]', 'ys = [ 9 ]'], fields: Array.from({ length: n }, (_, i) => `f${i} = ${i === 0 ? 'xs' : i === n - 1 ? 'ys' : `[ ${i} ]`}`), live: 'ys' }),
};

function program(n, writeName, recordName, live) {
  const rec = records[recordName](n);
  if (live && rec.live === null) return null;
  const ws = writes[writeName](n);
  const pre = rec.pre.map((l) => `    ${l}\n`).join('');
  return `import Node


type alias R =
${Array.from({ length: n }, (_, i) => `    f${i} : List Int`).join('\n')}


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


grow : R → R
grow r =
    { r
        | ${ws.join('\n        , ')}
    }


main : Node.Program
main =
${pre}    r =
        { ${rec.fields.join('\n        , ')}
        }
    s = grow r
    Node.print (ints s.f0 ++ " ; " ++ ints s.f1 ++ " ; " ++ ints s.f${n - 1}${live ? ` ++ " / " ++ ints ${rec.live}` : ''})
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const n of sizes) {
  for (const write of Object.keys(writes)) {
    for (const record of Object.keys(records)) {
      for (const live of [false, true]) {
        const name = `n${n}.${write}.${record}.${live ? 'live' : 'dead'}`;
        if (filter && !name.includes(filter)) continue;
        const src = program(n, write, record, live);
        if (src === null) continue;
        const d = path.join(out, name);
        fs.mkdirSync(d, { recursive: true });
        fs.writeFileSync(path.join(d, 'Main.beni'), src);
        list.push(d);
      }
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
