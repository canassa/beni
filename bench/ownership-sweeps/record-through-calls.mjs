// record-through-calls.mjs: a record that goes through several calls of a function that writes each field (#2535).
//
//   node bench/ownership-sweeps/record-through-calls.mjs <outdir> [filter]
//
// Each call gives the record a new name, and each write of a call is tested against each later
// read of the record (kernel §5, test 4). A read of a record that the frame made tests the runs of
// its root; while they are all old names for the write, the test is one step (kernel §8, *The runs
// of a root that are all old names are tested in one step*). The programs vary what the later reads
// are, so that the tests that are one step and the tests that are not are both there:
//   n       the fields of the record: 4, 40 and 100
//   calls   the calls that the record goes through: 2 and 10
//   field   int     a number, `step` adds one to each field
//           list    a list, `step` pushes onto each field
//   form    pipe    `init n ▷ step ▷ step`: no version has a name
//           lets    each version has a name
//   twin    dead    only the last version is read after the calls
//           first   the first version is read after the calls too (form `lets`)
//           mid     the version in the middle is read after the calls too (form `lets`)
// A live twin that is accepted and written in place prints another output than the plain build or
// traps: `run.mjs` finds both.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
const filter = process.argv[3];
if (!out) {
  console.error('usage: node bench/ownership-sweeps/record-through-calls.mjs <outdir> [filter]');
  process.exit(2);
}

const sizes = [4, 40, 100];
const callCounts = [2, 10];

const fields = {
  int: { type: 'Int', init: () => 'k', step: (i) => `w.f${i} + 1`, show: (v) => `String.fromInt ${v}` },
  list: { type: 'List Int', init: (i) => `[ k, ${i} ]`, step: (i) => `List.push w.f${i} ${i}`, show: (v) => `ints ${v}` },
};

function program(n, calls, fieldName, form, twin) {
  const fd = fields[fieldName];
  if (form === 'pipe' && twin !== 'dead') return null;
  const body = [];
  if (form === 'pipe') {
    body.push('    r =', '        init n');
    for (let c = 0; c < calls; c += 1) body.push('            ▷ step');
    body.push('    show r');
  } else {
    body.push('    r0 = init n');
    for (let c = 1; c <= calls; c += 1) body.push(`    r${c} = step r${c - 1}`);
    const old = twin === 'first' ? 0 : Math.floor(calls / 2);
    body.push(twin === 'dead' ? `    show r${calls}` : `    show r${calls} ++ " / " ++ ${fd.show(`r${old}.f0`)} ++ " / " ++ ${fd.show(`r${old}.f${n - 1}`)}`);
  }
  return `import Node


type alias W =
${Array.from({ length: n }, (_, i) => `    f${i} : ${fd.type}`).join('\n')}


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


init : Int → W
init k =
    { ${Array.from({ length: n }, (_, i) => `f${i} = ${fd.init(i)}`).join('\n    , ')}
    }


step : W → W
step w =
    { w
        | ${Array.from({ length: n }, (_, i) => `f${i} = ${fd.step(i)}`).join('\n        , ')}
    }


show : W → String
show w = ${fd.show('w.f0')} ++ " ; " ++ ${fd.show(`w.f${n - 1}`)}


go : Int → String
go n =
${body.join('\n')}


main : Node.Program
main = Node.print (go 1)
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const n of sizes) {
  for (const calls of callCounts) {
    for (const field of Object.keys(fields)) {
      for (const [form, twin] of [['pipe', 'dead'], ['lets', 'dead'], ['lets', 'first'], ['lets', 'mid']]) {
        const name = `n${n}.c${calls}.${field}.${form}.${twin}`;
        if (filter && !name.includes(filter)) continue;
        const src = program(n, calls, field, form, twin);
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
