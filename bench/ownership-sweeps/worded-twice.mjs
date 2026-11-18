// worded-twice.mjs <outdir> [filter]: research report 156, a worded row whose result holds one cell at two
// places of a summary location (a list's elements). A row builds no run, so nothing derives that each cell
// is at one place; the result's summary locations are `twice` unless a word states the positions
// (ownership-v3-kernel.md §4.4, §6 rule 10). Before the report v3 read a row's result as holding each cell
// once, so the parts of a list pattern (`[ b, …rest ]`) were apart and an in-place write of `b` was
// accepted while `rest` held the same record. Families:
//
// - `row.<row>.<carrier>.<pattern>.<write>`: a test platform (`_wordedtwice`, written next to the programs)
//   has `foreign` rows whose JavaScript puts one value at two places of the result, each true of the may-
//   reading of its words: `stored a → fresh List a` (`[a, a]`), `stored a, stored a → fresh List a`
//   (`[a, b, a]`), a row with no parameter cell (`unused Int → fresh List PR`, `() => [r, r]`), a fresh
//   type variable read as a list (`unused Int → fresh a`), a list inside a pair (`stored a → fresh List a ×
//   Int`), a `Js.Value` made by a row and read back through `Js.to`, an element of a list of lists
//   (`elementof a` answering `[l[i][0], l[i][0]]`), and one list in two records (`stored List Int → fresh
//   List PR`). Carrier: a local, a parameter, a parameter two calls deep, a wrapper in a second module, a
//   generic wrapper, a record field. Pattern: `[ b, …rest ]`, `[ …rest, b ]`. Write: the item's slot, or a
//   push of its nested list in a new record. Each reads `rest` after the write (`live`) or not (`dead`).
// - `core.<maker>.<carrier>.<pattern>.<write>`: the safe twins over the rows of `core/` whose words state
//   positions (`push`, `insertAt`, `set`, `cons` through `[ x, …l ]`, `copy`, `++`, `take`, `reverse`, `map`):
//   two new records, so each is `SAME` where accepted.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/worded-twice.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const progs = [];
const add = (name, files) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files });
};
const platformDir = path.join(path.resolve(out), '_wordedtwice');
const platformRel = path.relative(root, platformDir);

const platform = `--! A sweep's platform: rows whose JavaScript puts one value at two places of the result.

import Js


pub type alias PR =
    x : Int
    xs : List Int


--| JavaScript [a, a].
pub foreign pure dupW : stored a → fresh List a


--| JavaScript [a, b, a].
pub foreign pure tripW : stored a, stored a → fresh List a


--| JavaScript a new record twice: [r, r].
pub foreign pure mkW : unused Int → fresh List PR


--| JavaScript a new record twice, at a type variable.
pub foreign pure mkG : unused Int → fresh a


--| JavaScript {a: [a, a], b: 0}.
pub foreign pure pairW : stored a → fresh List a × Int


--| JavaScript [l[i][0], l[i][0]].
pub foreign pure elemG : borrowed List a, borrowed Int → elementof a


--| JavaScript [{x: 1, xs: l}, {x: 2, xs: l}].
pub foreign pure shareW : stored List Int → fresh List PR


--| JavaScript [[a], [a]].
pub foreign pure nestW : stored a → fresh List (List a)


--| JavaScript {items: [a, a], k: 0}.
pub foreign pure recW : stored a → fresh { items : List a, k : Int }


--| A list read through \`Js\` and back.
pub castL : List a → List a
castL l =
    Js.to (Js.from l)


--| JavaScript a new record twice, as a host value.
pub foreign pure mkV : unused Int → fresh Js.Value


--| The first part of a pair.
pub firstOf : a × b → a
firstOf p =
    case p of
        ( l, _ ) →
            l


--| The host value read as a list.
pub viaV : Int → List PR
viaV n =
    Js.to (mkV n)
`;
const platformJs = `export const dupW = (a) => [a, a];
export const tripW = (a, b) => [a, b, a];
export const mkW = (n) => { const r = { x: n, xs: [n] }; return [r, r]; };
export const mkG = (n) => { const r = { x: n, xs: [n] }; return [r, r]; };
export const pairW = (a) => ({ a: [a, a], b: 0 });
export const elemG = (l, i) => [l[i][0], l[i][0]];
export const shareW = (l) => [{ x: 1, xs: l }, { x: 2, xs: l }];
export const nestW = (a) => [[a], [a]];
export const recW = (a) => ({ items: [a, a], k: 0 });
export const mkV = (n) => { const r = { x: n, xs: [n] }; return [r, r]; };
`;

// name, the expression that makes the list (of `PR`), from `n`.
const rows = {
  dupW: 'Probe.dupW (mk n)',
  tripW: 'Probe.tripW (mk n) (mk (n + 1))',
  mkW: 'Probe.mkW n',
  mkG: 'Probe.mkG n',
  pairW: 'Probe.firstOf (Probe.pairW (mk n))',
  elemG: 'Probe.elemG [ [ mk n ] ] 0',
  shareW: 'Probe.shareW [ n ]',
  viaV: 'Probe.viaV n',
  nestW: 'List.concat (Probe.nestW (mk n))',
  recW: '(Probe.recW (mk n)).items',
  dictW: 'Dict.values (Dict.fromList (List.indexedMap (Probe.dupW (mk n)) λi q → ( i, q )))',
};
const cores = {
  push: 'List.push (List.push [] (mk n)) (mk (n + 1))',
  insertAt: 'List.insertAt [ mk n ] 0 (mk (n + 1))',
  set: 'List.set [ mk n, mk n ] 1 (mk (n + 1))',
  cons: 'consOn (mk n) [ mk (n + 1) ]',
  copy: 'List.copy [ mk n, mk (n + 1) ]',
  append: '[ mk n ] ++ [ mk (n + 1) ]',
  take: 'List.take [ mk n, mk (n + 1), mk 3 ] 2',
  reverse: 'List.reverse [ mk n, mk (n + 1) ]',
  map: 'List.map [ n, n + 1 ] mk',
};
const patterns = {
  head: ['[ b, …rest ]', '[]'],
  last: ['[ …rest, b ]', '[]'],
};
const writes = {
  slot: '{ b | x = 99 }',
  npush: '{ x = 0, xs = List.push b.xs 7 }',
};

function program(maker, carrier, pat, write, live) {
  const [p] = patterns[pat];
  const use = live ? '"${show w} ${showAll rest}"' : '"${show w}"';
  const gg = `gg : List PR → String
gg list =
    case list of
        ${p} →
            w = ${writes[write]}
            ${use}

        _ →
            "none"
`;
  const local = `run : Int → String
run n =
    list : List PR
    list = ${maker}
    case list of
        ${p} →
            w = ${writes[write]}
            ${use}

        _ →
            "none"
`;
  const files = {};
  let body;
  let extra = '';
  switch (carrier) {
    case 'local': body = local; break;
    case 'param': body = `${gg}

run : Int → String
run n =
    list : List PR
    list = ${maker}
    gg list
`; break;
    case 'param2': body = `${gg}

hh : List PR → String
hh l =
    gg l


run : Int → String
run n =
    list : List PR
    list = ${maker}
    hh list
`; break;
    case 'other':
      extra = '\nimport Lib';
      files['Lib.beni'] = `import Dict
import Probe exposing (PR)


consOn : PR, List PR → List PR
consOn h t =
    [ h, …t ]


pub make : (Int → PR), Int → List PR
make mk n =
    ${maker}
`;
      body = `${gg}

run : Int → String
run n =
    gg (Lib.make mk n)
`; break;
    case 'generic': body = `${gg}

wrap : (⊤ → a) → a
wrap f =
    f ⊤


run : Int → String
run n =
    list : List PR
    list = wrap λ⊤ → ${maker}
    gg list
`; break;
    case 'map': body = `${gg}

run : Int → String
run n =
    sep = ";"
    String.join (List.map [ ${maker} ] gg) sep
`; break;
    case 'cast': body = `${gg}

run : Int → String
run n =
    gg (Probe.castL (${maker}))
`; break;
    case 'field': body = `${gg}

type alias Box =
    items : List PR
    k : Int


run : Int → String
run n =
    box = { items = ${maker}, k = 1 }
    gg box.items
`; break;
  }
  files['Main.beni'] = `import Node exposing (Program)
import Dict
import Probe exposing (PR)${extra}


mk : Int → PR
mk n = { x = n, xs = [ n ] }


consOn : PR, List PR → List PR
consOn h t =
    [ h, …t ]


show : PR → String
show r =
    sep = ":"
    "\${String.fromInt r.x}/\${String.join (List.map r.xs String.fromInt) sep}"


showAll : List PR → String
showAll rs =
    sep = ","
    String.join (List.map rs show) sep


${body}

main : Program
main = Node.print (run 1)
`;
  return files;
}

const carriers = ['local', 'param', 'param2', 'other', 'generic', 'field', 'map', 'cast'];
for (const [kind, makers] of [['row', rows], ['core', cores]]) {
  for (const [m, maker] of Object.entries(makers)) for (const c of carriers) for (const p of Object.keys(patterns)) for (const w of Object.keys(writes)) for (const live of [true, false]) {
    add(`${kind}.${m}.${c}.${p}.${w}.${live ? 'live' : 'dead'}`, program(maker, c, p, w, live));
  }
}

// The entry: a page whose `init` makes the model's list with a row, and whose `update` writes an item of
// a list pattern over it and keeps the rest (`live`), or keeps only the written item (`dead`).
const pageDir = path.join(path.resolve(out), '_wordedtwicepage');
const pageRel = path.relative(root, pageDir);
const entryMakers = { dupW: 'Probe.dupW (mk 1)', mkW: 'Probe.mkW 1', tripW: 'Probe.tripW (mk 1) (mk 2)', push: 'List.push [ mk 1 ] (mk 2)' };
for (const [m, maker] of Object.entries(entryMakers)) for (const live of [true, false]) {
  add(`entry.${m}.${live ? 'live' : 'dead'}`, { page: true, 'steps': 'click #go\n', 'Main.beni': `import Page exposing (Node)
import Probe exposing (PR)


type alias Model =
    rows : List PR


type Msg
    = Go


mk : Int → PR
mk n = { x = n, xs = [ n ] }


init : ⊤ → Model
init _ =
    { rows = ${maker} }


update : Msg, Model → Model
update msg model =
    case msg of
        Go →
            case model.rows of
                [ b, …rest ] →
                    w = { b | x = 99 }
                    { model | rows = ${live ? '[ w, …rest ]' : '[ w ]'} }

                [] →
                    model


view : Model → Node Msg
view model =
    sep = ","
    Page.element "main" []
        [ Page.element "button" [ Page.attribute "id" "go", Page.onClick Go ] [ Page.text "go" ]
        , Page.element "output" [] [ Page.text (String.join (List.map model.rows λq → String.fromInt q.x) sep) ]
        ]


main : Page.Program
main = Page.sandbox { init = init, update = update, view = view }
` });
}

fs.mkdirSync(pageDir, { recursive: true });
for (const f of ['Page.beni', 'Page.js', 'runtime.js']) fs.copyFileSync(path.join(root, 'tests/platforms/page', f), path.join(pageDir, f));
fs.writeFileSync(path.join(pageDir, 'beni.json'), '{ "platform": true, "name": "wordedtwicepage", "program": "Page.Program", "runtime": "runtime.js" }\n');
fs.writeFileSync(path.join(pageDir, 'Probe.beni'), platform.replace(/\nimport Js\n/, '\nimport Js\n'));
fs.writeFileSync(path.join(pageDir, 'Probe.js'), platformJs);
fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "wordedtwice", "platforms": ["node"], "reexports": ["Node", "Probe"] }\n');
fs.writeFileSync(path.join(platformDir, 'Probe.beni'), platform);
fs.writeFileSync(path.join(platformDir, 'Probe.js'), platformJs);
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(p.files)) if (f !== 'page') fs.writeFileSync(path.join(d, f), text);
  fs.writeFileSync(path.join(d, 'PLATFORM'), `${p.files.page ? pageRel : platformRel}\n`);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
