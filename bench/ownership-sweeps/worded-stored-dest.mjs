// worded-stored-dest.mjs <outdir> [filter]: research report 157, `stored` beside a `written returned` parameter
// that is no list at its root. `stored` is one write at one position of the one list a row writes and answers
// (ownership-v3-kernel.md §4.4); where the `written returned` parameter is a record or an `Int`, or the result
// is no list at its root, the words state no position and the result's elements are `twice`. Before the
// report the marker read such a store as one position and the safe-build check did not: a record destination
// panicked every v3 build of its platform (#2559), and an `Int` destination with a list result was read as
// once, so `[ b, …rest ]` over `[v, v]` wrote `b` in place while `rest` held it. Families:
//
// - `row.<row>.<carrier>.<twin>`: a test platform (`_storeddest`, written next to the programs) has rows whose
//   JavaScript puts the stored value at two places (`…2`) or one (`…1`) of the result's list: a record
//   destination (`recN`: `written returned { items : List a }, stored a → { items : List a }`), an `Int`
//   destination answering a record (`intRecN`) or a list (`intN`), and `List.push` (`push`, the core twin).
//   Carrier: a local, a parameter, a call two deep. The program matches `[ b, …rest ]` over the list, updates
//   `b`, and reads `rest` after (`live`) or not (`dead`).
// - `nest.<row>.<twin>`: a stored `List Int` that is no element of the `List (List (List Int))` the row
//   writes, put below an element twice: `stored` (`nest`), a stored callback (`focusNest`), `prepended`'s
//   item (`consNest`). The program matches the one element, then `[ b, …rest ]` in it, and pushes onto `b`.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/worded-stored-dest.mjs <outdir> [filter]'); process.exit(2); }
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const platformDir = path.join(path.resolve(out), '_storeddest');
const platformRel = path.relative(root, platformDir);

const platform = `--! A sweep's platform: rows that store an item beside a \`written returned\` parameter.

--| JavaScript \`r.items = r.items.concat([v, v]); return r\`.
pub foreign pure rec2 : written returned { items : List a }, stored a → { items : List a }


--| JavaScript \`r.items = r.items.concat([v]); return r\`.
pub foreign pure rec1 : written returned { items : List a }, stored a → { items : List a }


--| JavaScript \`({ items: [v, v] })\`.
pub foreign pure intRec2 : written returned Int, stored a → { items : List a }


--| JavaScript \`({ items: [v] })\`.
pub foreign pure intRec1 : written returned Int, stored a → { items : List a }


--| JavaScript \`[v, v]\`.
pub foreign pure int2 : stored a, written returned Int → List a


--| JavaScript \`[v]\`.
pub foreign pure int1 : stored a, written returned Int → List a


--| JavaScript \`l.push([a, a]); return l\`.
pub foreign pure nest : written returned List (List (List Int)), stored (List Int) → List (List (List Int))


--| JavaScript \`const a = g(l[i][0]); l[i] = [a, a]; return l\`.
pub foreign pure focusNest : written returned List (List (List Int)), borrowed Int, once taken stored (List Int → List Int) → List (List (List Int))


--| JavaScript \`[[a, a], ...l]\`.
pub foreign pure consNest : stored (List Int), returned List (List (List Int)) → prepended List (List (List Int))
`;
const platformJs = `export const rec2 = (r, v) => { r.items = r.items.concat([v, v]); return r; };
export const rec1 = (r, v) => { r.items = r.items.concat([v]); return r; };
export const intRec2 = (n, v) => ({ items: [v, v] });
export const intRec1 = (n, v) => ({ items: [v] });
export const int2 = (v, n) => [v, v];
export const int1 = (v, n) => [v];
export const nest = (l, a) => { l.push([a, a]); return l; };
export const focusNest = (l, i, g) => { const a = g(l[i][0]); l[i] = [a, a]; return l; };
export const consNest = (a, l) => [[a, a], ...l];
`;

const makers = {
  rec2: 'Probe.rec2 { items = [] } (mk 1)).items',
  rec1: 'Probe.rec1 { items = [ mk 2 ] } (mk 1)).items',
  intRec2: 'Probe.intRec2 0 (mk 1)).items',
  intRec1: 'Probe.intRec1 0 (mk 1)).items',
  int2: 'Probe.int2 (mk 1) 0)',
  int1: 'Probe.int1 (mk 1) 0)',
  push: 'List.push [ mk 2 ] (mk 1))',
};
const carriers = {
  local: (make) => `main : Program\nmain =\n    l = (${make}\n    Node.print (gg l)\n`,
  param: (make) => `via : R → String\nvia r =\n    gg (${make.replaceAll('(mk 1)', 'r')}\n\n\nmain : Program\nmain = Node.print (via (mk 1))\n`,
  deep: (make) => `via : R → String\nvia r =\n    gg (${make.replaceAll('(mk 1)', 'r')}\n\n\nouter : Int → String\nouter n = via (mk n)\n\n\nmain : Program\nmain = Node.print (outer 1)\n`,
};
const twins = {
  live: '            "${String.fromInt w.x} ${String.fromInt (total rest)}"',
  dead: '            "${String.fromInt w.x}"',
};

const progs = [];
for (const [mk, make] of Object.entries(makers)) for (const [cn, carrier] of Object.entries(carriers)) for (const [tn, tail] of Object.entries(twins)) {
  const name = `row.${mk}.${cn}.${tn}`;
  if (filter && !name.includes(filter)) continue;
  progs.push({ name, main: `import Node exposing (Program)
import Probe


type alias R =
    x : Int
    xs : List Int


mk : Int → R
mk n = { x = n, xs = [ n ] }


total : List R → Int
total rs = List.sum (List.map rs λq → q.x)


gg : List R → String
gg list =
    case list of
        [ b, …rest ] →
            w = { b | x = 99 }
${tail}

        _ →
            "none"


${carrier(make)}` });
}

const nests = { nest: 'Probe.nest [] [ 1 ]', focusNest: 'Probe.focusNest [ [ [ 1 ] ] ] 0 λq → q', consNest: 'Probe.consNest [ 1 ] []' };
for (const [mk, make] of Object.entries(nests)) for (const tn of ['live', 'dead']) {
  const name = `nest.${mk}.${tn}`;
  if (filter && !name.includes(filter)) continue;
  progs.push({ name, main: `import Node exposing (Program)
import Probe


lens : List (List Int) → Int
lens ls = List.sum (List.map ls λq → List.length q)


gg : List (List Int) → String
gg list =
    case list of
        [ b, …rest ] →
            w = List.push b 5
            ${tn === 'live' ? '"${String.fromInt (List.length w)} ${String.fromInt (lens rest)}"' : '"${String.fromInt (List.length w)}"'}

        _ →
            "none"


main : Program
main =
    case ${make} of
        [ inner ] →
            Node.print (gg inner)

        _ →
            Node.print "no"
` });
}

fs.mkdirSync(platformDir, { recursive: true });
fs.writeFileSync(path.join(platformDir, 'beni.json'), '{ "platform": true, "name": "storeddest", "platforms": ["node"], "reexports": ["Node", "Probe"] }\n');
fs.writeFileSync(path.join(platformDir, 'Probe.beni'), platform);
fs.writeFileSync(path.join(platformDir, 'Probe.js'), platformJs);
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  fs.writeFileSync(path.join(d, 'PLATFORM'), `${platformRel}\n`);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
