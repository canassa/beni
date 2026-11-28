// as-scrutinees.mjs <outdir> [filter]: research report 152, a `case` whose pattern binds a name to the
// whole scrutinee or to a part of it — `p as w`, a bare variable arm after a tested one, `as` one level
// down, `…rest` — in a release build. The lowering hands the binding and the decision tree's tests one
// node of the subject, and the specialiser's dead-binding rule rewrote that node when the name was unused,
// so the other readers of it read `undefined` (#2547, and the blind round W's `RIPTRAP`).
//
// Axes: the scrutinee's shape (a list, a pair, a record, a constructor) × its pattern (`as` at the top, `as`
// one level down, `as` over a pattern with `…rest`, a bare variable arm after a tested arm, a record update
// of the `as` name) × where the scrutinee comes from (a local, a value built in the `case` itself, a
// parameter of a helper) × what the arm answers (the bound name, only the parts, or the `case` is unused) ×
// the argument (a constant the specialiser folds, or a value it cannot see) × a push of the scrutinee's
// list after the `case`, read with the answer (`live`) or alone (`dead`), or no write (`none`).
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/as-scrutinees.mjs <outdir> [filter]'); process.exit(2); }
const progs = [];
const add = (name, files) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files });
};

// Per shape: the type, how a value is made of `n`, its list part (what the write pushes), how it is shown,
// and its patterns. A pattern's `arms` take the answer of its binding arm, `used` reads the bound name and
// `parts` only what the pattern took apart.
const shapes = {
  list: {
    type: 'List Int',
    make: (n) => `[ ${n}, 4 ]`,
    listOf: (v) => v,
    show: (h) => `String.join (List.map ${h} String.fromInt) ","`,
    pats: {
      as: { arms: (a) => [`([ a, …_ ] as w) →\n${a}`, '[] →\n[]'], used: 'w', parts: '[ a ]' },
      asrest: { arms: (a) => [`([ a, …rest ] as w) →\n${a}`, '[] →\n[]'], used: '[ …w, …rest ]', parts: '[ a, …rest ]' },
      inner: { arms: (a) => [`[ (a as el), …_ ] →\n${a}`, '[] →\n[]'], used: '[ el, a ]', parts: '[ a ]' },
      var: { arms: (a) => ['[] →\n[]', `w →\n${a}`], used: 'w', parts: '[ 1 ]' },
    },
  },
  pair: {
    type: 'List Int × Int',
    make: (n) => `( [ ${n}, 4 ], ${n} )`,
    listOf: (v) => `${v}.0`,
    show: (h) => `String.fromInt (List.length ${h}.0) ++ "/" ++ String.fromInt ${h}.1`,
    pats: {
      as: { arms: (a) => [`( a, b ) as t →\n${a}`], used: '( a, t.1 + b )', parts: '( a, b )' },
      inner: { arms: (a) => [`( (a as l), b ) →\n${a}`], used: '( l, b )', parts: '( a, b )' },
      tested: { arms: (a) => ['( [], b ) →\n( [], b )', `( a, _ ) as t →\n${a}`], used: 't', parts: '( a, 0 )' },
      var: { arms: (a) => ['( [], b ) →\n( [], b )', `t →\n${a}`], used: 't', parts: '( [ 1 ], 0 )' },
    },
  },
  record: {
    type: 'R',
    make: (n) => `{ x = ${n}, l = [ ${n}, 4 ] }`,
    listOf: (v) => `${v}.l`,
    show: (h) => `String.fromInt ${h}.x ++ "/" ++ String.fromInt (List.length ${h}.l)`,
    pats: {
      as: { arms: (a) => [`{ x, l } as r →\n${a}`], used: 'r', parts: '{ x = x, l = l }' },
      upd: { arms: (a) => [`{ x, l } as r →\n${a}`], used: '{ r | x = r.x + x }', parts: '{ x = x + 1, l = l }' },
    },
  },
  ctor: {
    type: 'T',
    make: (n) => `A [ ${n}, 4 ] ${n}`,
    listOf: (v) => `(listOf ${v})`,
    show: (h) => `showT ${h}`,
    pats: {
      as: { arms: (a) => [`(A l k) as w →\n${a}`, 'B →\nB'], used: 'w', parts: 'A l k' },
      inner: { arms: (a) => [`A ([ _, …_ ] as l) k →\n${a}`, 'A [] k →\nA [] k', 'B →\nB'], used: 'A l k', parts: 'A [ 1 ] k' },
      var: { arms: (a) => ['B →\nB', `w →\n${a}`], used: 'w', parts: 'B' },
    },
  },
};

const indent = (text, by) => text.split('\n').map((l) => (l.length ? ' '.repeat(by) + l : l)).join('\n');
const caseOf = (scrut, arms, at) =>
  `case ${scrut} of\n${arms.map((a) => indent(a.replace('\n', '\n    '), 4)).join('\n\n')}`.split('\n').map((l, i) => (i && l.length ? " ".repeat(at) + l : l)).join('\n');

const header = `import List
import Node exposing (Program)
import String


type alias R =
    x : Int
    l : List Int


type T
    = A (List Int) Int
    | B


listOf : T → List Int
listOf t =
    case t of
        A l _ →
            l

        B →
            []


showT : T → String
showT t =
    case t of
        A l k →
            "A " ++ String.fromInt (List.length l) ++ " " ++ String.fromInt k

        B →
            "B"
`;

for (const [sname, shape] of Object.entries(shapes)) {
  for (const [pname, pat] of Object.entries(shape.pats)) {
    for (const src of ['local', 'inline', 'param']) {
      for (const use of ['used', 'parts', 'unused']) {
        for (const arg of ['const', 'dyn']) {
          for (const write of ['none', 'push']) {
            const answer = use === 'used' ? pat.used : pat.parts;
            const arms = pat.arms(answer);
            const lines = [];
            let helper = '';
            if (src === 'param') {
              helper = `\n\npick : ${shape.type} → ${shape.type}\npick v =\n    ${caseOf('v', arms, 4)}\n`;
            }
            lines.push(`    v0 = ${shape.make('n')}`);
            const scrut = src === 'inline' ? `(${shape.make('n')})` : 'v0';
            const hval = src === 'param' ? 'pick v0' : caseOf(scrut, arms, 8);
            lines.push(`    h =\n        ${hval}`);
            if (write === 'push') lines.push(`    v1 = List.push ${shape.listOf('v0')} 9`);
            const shown = [];
            if (use !== 'unused') shown.push(shape.show('h'));
            shown.push(`String.fromInt (List.length ${shape.listOf('v0')})`);
            if (write === 'push') shown.push('String.fromInt (List.length v1)');
            lines.push(`    ${shown.join(' ++ " " ++ ')}`);
            const call = arg === 'const' ? 'go 3' : 'go (List.length (List.range 1 3))';
            const twin = write === 'none' ? 'none' : use === 'unused' ? 'dead' : 'live';
            const name = `${sname}.${pname}.${src}.${use}.${arg}.${twin}`;
            const main = `${header}${helper}

go : Int → String
go n =
${lines.join('\n')}


main : Program
main = Node.print (${call})
`;
            add(name, { 'Main.beni': main });
          }
        }
      }
    }
  }
}

const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(p.files)) fs.writeFileSync(path.join(d, f), text);
  list.push(d);
}
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
