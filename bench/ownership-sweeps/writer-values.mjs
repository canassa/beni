// writer-values.mjs <outdir> [filter]: a generator for writers of core named as values (research report
// 163, #2574). A writer of `Dict`, `Set` or `List` is bound to `w` by one of several productions (a `let`
// alias, an identity's answer, a lambda's, another module's identity, a platform's alias, a record's
// field, a list, a `Maybe`, a tuple, a function's answer), then used: called, handed to a function of
// this module or of another, captured by a closure that is called or handed on, or partly applied. The
// written base `b0` is read after the write in the `live` twin and not in the `dead` one. Kernel §12
// item 5: each run of a writer value is judged where it runs and the value is routed where it is made,
// or the form is refused; there is no copying form. A refusal of a `dead` twin is a precision loss (or
// a kept form, which is refused by design); a TRAP or DIFF of any is a soundness hole. Programs are
// `<writer>.<production>.<use>.<twin>/`. See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/writer-values.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const park = 'λk _ →\n    Io.sleep 1\n    0 - k';
const parkL = 'λn →\n    Io.sleep 1\n    n + 100';

// Each writer: its value, its function type, the base type, how a base is made, the arguments after the
// base, how the answer is shown, and whether its callback parks.
const D = 'Dict Int Int';
const WRITERS = {
  dIns: { v: 'Dict.insert', t: `${D}, Int, Int → ${D}`, b: D, mk: 'Dict.fromList [ ( 1, 10 ), ( 2, 20 ) ]', args: '3 30', show: 'renderD' },
  dRem: { v: 'Dict.remove', t: `${D}, Int → ${D}`, b: D, mk: 'Dict.fromList [ ( 1, 10 ), ( 2, 20 ) ]', args: '1', show: 'renderD' },
  dUpd: { v: 'Dict.update', t: `${D}, Int, (Maybe Int → Maybe Int) → ${D}`, b: D, mk: 'Dict.fromList [ ( 1, 10 ), ( 2, 20 ) ]', args: '1 λ_ → Just 7', show: 'renderD' },
  dSortP: { v: 'Dict.sortBy', t: `${D}, (Int, Int → Int) → ${D}`, b: D, mk: 'Dict.fromList [ ( 1, 10 ), ( 2, 20 ) ]', args: park, show: 'renderD', parks: true },
  sIns: { v: 'Set.insert', t: 'Set Int, Int → Set Int', b: 'Set Int', mk: 'Set.fromList [ 1, 2 ]', args: '3', show: 'members' },
  lPush: { v: 'List.push', t: 'List Int, Int → List Int', b: 'List Int', mk: '[ 1, 2 ]', args: '3', show: 'ints' },
  lSet: { v: 'List.set', t: 'List Int, Int, Int → List Int', b: 'List Int', mk: '[ 1, 2 ]', args: '0 9', show: 'ints' },
  lUpdP: { v: 'List.update', t: 'List Int, Int, (Int → Int) → List Int', b: 'List Int', mk: '[ 1, 2 ]', args: `0 ${parkL}`, show: 'ints', parks: true },
};

// How `w` is bound (lines of `go`). `W` is the writer's value.
const PRODUCTIONS = {
  alias: (W) => [`w = ${W}`],
  idCall: (W) => [`w = idW ${W}`],
  idTwice: (W) => [`w = idW (idW ${W})`],
  lam: (W) => [`w = (λq → q) ${W}`],
  otherId: (W) => [`w = Other.idW ${W}`],
  aliasId: (W) => [`a = ${W}`, 'w = idW a'],
  plat: (_W, k) => [`w = Probe.${k}`],
  platId: (_W, k) => [`w = idW Probe.${k}`],
  field: (W) => [`r = { f = ${W} }`, 'w = r.f'],
  list: (W) => [`w = Maybe.withDefault (List.head [ ${W} ]) ${W}`],
  maybe: (W) => [`w = Maybe.withDefault (Just ${W}) ${W}`],
  tuple: (W) => [`( w, _ ) = ( ${W}, 0 )`],
  pick: () => ['w = pick ⊤'],
};

// How `w` is used on `b0`: lines that bind `x`.
const USES = {
  call: (a) => [`x = w b0 ${a}`],
  apply: () => ['x = applyW w b0'],
  applyOther: () => ['x = Other.applyW w b0'],
  closure: (a) => [`h = λb → w b ${a}`, 'x = h b0'],
  handed: (a) => [`x = applyOne b0 λb → w b ${a}`],
  partial: (a) => [`p = w _ ${a}`, 'x = p b0'],
};

const helpers = (wr, mod, pick = false) => `idW : (${wr.t}) → (${wr.t})
idW f = f


applyW : (${wr.t}), ${wr.b} → ${wr.b}
applyW f b =
${ind(`f b ${wr.args}`, 4)}
${mod === 'Main' ? `

applyOne : ${wr.b}, (${wr.b} → ${wr.b}) → ${wr.b}
applyOne b f = f b
${pick ? `

pick : ⊤ → (${wr.t})
pick ⊤ = ${wr.v}
` : ''}` : ''}`;

const SHOW = `renderD : Dict Int Int → String
renderD d =
    String.join (List.map (Dict.toList d) λ( k, v ) → "\${String.fromInt k}=\${String.fromInt v}") ","


members : Set Int → String
members s = String.join (List.map (Set.toList s) String.fromInt) ","


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","
`;

function gen(k, prod, use, live) {
  const wr = WRITERS[k];
  const lines = [`b0 = ${wr.mk}`, ...PRODUCTIONS[prod](wr.v, k), ...USES[use](wr.args)];
  lines.push(`[ ${[`${wr.show} x`, ...(live ? [`${wr.show} b0`] : [])].join(', ')} ]`);
  const plat = prod.startsWith('plat');
  const main = `import Dict exposing (Dict)
${wr.parks ? 'import Io\n' : ''}import Node exposing (Program)
import Other
${plat ? 'import Probe\n' : ''}import Set exposing (Set)


${SHOW}

${helpers(wr, 'Main', prod === 'pick')}

go : ⊤ → List String
go ⊤ =
${ind(lines.join('\n'), 4)}


main : Program
main = ${wr.parks ? 'Io.run λ⊤ → ' : ''}Node.printLines (go ⊤)
`;
  const other = `import Dict exposing (Dict)
${wr.parks ? 'import Io\n' : ''}import Set exposing (Set)


pub ${helpers(wr, 'Other').replace('\napplyW :', '\npub applyW :')}`;
  return { 'Main.beni': main, 'Other.beni': other };
}

// The platform layer: an alias of each writer.
fs.mkdirSync(out, { recursive: true });
const plat = path.resolve(out, '_plat');
fs.mkdirSync(plat, { recursive: true });
fs.writeFileSync(path.join(plat, 'beni.json'), '{ "platform": true, "name": "wvprobe", "platforms": ["node"], "reexports": ["Node", "Io"] }\n');
fs.writeFileSync(path.join(plat, 'Probe.beni'), `--! Aliases of core's writers, read by the app as values.\nimport Dict exposing (Dict)\nimport Set exposing (Set)\n\n\n${Object.entries(WRITERS).map(([k, w]) => `pub ${k} : (${w.t})\n${k} = ${w.v}\n`).join('\n\n')}`);
const list = [];
for (const k of Object.keys(WRITERS)) for (const prod of Object.keys(PRODUCTIONS)) for (const use of Object.keys(USES)) for (const live of [false, true]) {
  const name = `${k}.${prod}.${use}.${live ? 'live' : 'dead'}`;
  if (filter && !name.includes(filter)) continue;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(gen(k, prod, use, live))) fs.writeFileSync(path.join(d, f), text);
  if (prod.startsWith('plat')) fs.writeFileSync(path.join(d, 'PLATFORM'), `${path.relative(root, plat)}\n`);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
