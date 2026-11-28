// precision-154.mjs <outdir> [filter]: the acceptances of research report 154 crossed with live twins.
//
// `parts.<scrut>.<pat>.<write>.<read>.<twin>`: a list pattern binds `a` (and `b`) and the rest of a
// list of records; `a` is written in place, then something is read (`ownership-v3-kernel.md` §4.4,
// *The parts of a list pattern are apart*). `<scrut>` is the list: `param` a parameter, `lit` a literal
// of distinct records, `map` a call's answer, and the lists that hold one record twice, `dup` (a
// literal), `repeat` (`List.repeat`) and `dupparam` (a parameter its caller made so). `<pat>` is `head`
// (`[ a, …rest ]`), `last` (`[ …rest, a ]`) or `two` (`[ a, b, …rest ]`). `<read>` is `rest` and
// `other` (`b`), apart from `a` unless the list holds a record twice; `whole` (the list) and `again`
// (`a` itself) read the written record.
//
// `walk.<kind>.<twin>`: a recursive walk `[ b, …rest ] → loop rest (List.push acc (bump b))`; `rot.<kind>`:
// `rest ++ [ x ]`, whose answer holds each cell once where the list does.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/precision-154.mjs <outdir> [filter]'); process.exit(2); }
const progs = [];
const add = (name, main) => { if (name.includes(filter)) progs.push({ name, main }); };

const HEAD = `import Node exposing (Program)
import String


type alias R =
    x : Int
    xs : List Int


mk : Int → R
mk n = { x = n, xs = [ n ] }


show : R → String
show r = "\${String.fromInt r.x}/\${String.fromInt (List.length r.xs)}"


showAll : List R → String
showAll rs = String.join (List.map rs show) ","


bump : R → R
bump r = { r | x = r.x + 10 }
`;

const ind = (s, n) => s.split('\n').map((l) => ' '.repeat(n) + l).join('\n');

const SCRUTS = {
  param: { local: null, call: 'f [ mk 1, mk 2, mk 3 ]', dup: false },
  dupparam: { local: null, call: 'f (dupd 1)', dup: true },
  lit: { local: 'list = [ mk n, mk (n + 1), mk (n + 2) ]', dup: false },
  map: { local: 'list = List.map [ n, n + 1, n + 2 ] mk', dup: false },
  dup: { local: 'r = mk n\nlist = [ r, r, mk (n + 2) ]', dup: true },
  repeat: { local: 'list = List.repeat (mk n) 3', dup: true, all: true },
};
const PATS = {
  head: '[ a, …rest ]',
  last: '[ …rest, a ]',
  two: '[ a, b, …rest ]',
};
const WRITES = {
  upd: '{ a | x = 99 }',
  push: '{ a | xs = List.push a.xs 7 }',
  helper: 'bump a',
};
const READS = {
  rest: { e: 'showAll rest', apart: true },
  other: { e: 'show b', apart: true, pats: ['two'] },
  whole: { e: 'showAll list', apart: false },
  again: { e: 'show a', apart: false },
};

for (const [sc, S] of Object.entries(SCRUTS)) for (const [pt, P] of Object.entries(PATS)) for (const [wr, W] of Object.entries(WRITES)) for (const [rd, R] of Object.entries(READS)) {
  if (R.pats && !R.pats.includes(pt)) continue;
  // `dup`'s and `dupparam`'s records 0 and 1 are one record: in `last`, `a` is the last, which is apart.
  const shared = S.all || (S.dup && !(pt === 'last'));
  const twin = R.apart && !shared ? 'dead' : 'live';
  const param = S.local === null;
  const body = `${param ? '' : S.local + '\n'}case list of
    ${P} →
        w = ${W}
        "\${show w} \${${R.e}}"

    _ →
        "none"`;
  const main = `${HEAD}

dupd : Int → List R
dupd n =
    r = mk n
    [ r, r, mk (n + 2) ]


f : ${param ? 'List R' : 'Int'} → String
f ${param ? 'list' : 'n'} =
${ind(body, 4)}


main : Program
main = Node.print (${param ? S.call : 'f 1'})
`;
  add(`parts.${sc}.${pt}.${wr}.${rd}.${twin}`, main);
}

// A recursive walk that writes each element, and its holders.
const WALKS = {
  dead: 'bs = [ mk 1, mk 2, mk 3 ]\nNode.print (showAll (loop bs []))',
  live: 'bs = [ mk 1, mk 2, mk 3 ]\nNode.print "\${showAll (loop bs [])} \${showAll bs}"',
  dup: 'r = mk 1\nNode.print (showAll (loop [ r, mk 2, r ] []))',
  acc: 'r = mk 1\nNode.print (showAll (loop [ r, mk 2 ] [ r ]))',
  map: 'Node.print (showAll (loop (List.map [ 1, 2, 3 ] mk) []))',
};
for (const [k, body] of Object.entries(WALKS)) {
  const main = `${HEAD}

loop : List R, List R → List R
loop bs acc =
    case bs of
        [ b, …rest ] →
            loop rest (List.push acc (bump b))

        [] →
            acc


main : Program
main =
${ind(body, 4)}
`;
  add(`walk.${k}.${k === 'dead' || k === 'map' ? 'dead' : 'live'}`, main);
}

// `rest ++ [ x ]`: its answer holds each record once where the list does.
const ROTS = {
  dead: 'ys = rot [ mk 1, mk 2, mk 3 ]\ncase ys of\n    [ a, …r ] →\n        "\${show (bump a)} \${showAll r}"\n\n    [] →\n        "none"',
  live: 'xs = [ mk 1, mk 2, mk 3 ]\nys = rot xs\ncase ys of\n    [ a, …r ] →\n        "\${show (bump a)} \${showAll xs}"\n\n    [] →\n        "none"',
  dup: 'r0 = mk 1\nys = rot [ r0, mk 2, r0 ]\ncase ys of\n    [ _, a, …r ] →\n        "\${show (bump a)} \${showAll r}"\n\n    _ →\n        "none"',
};
for (const [k, body] of Object.entries(ROTS)) {
  const main = `${HEAD}

rot : List R → List R
rot l =
    case l of
        [ x, …rest ] →
            rest ++ [ x ]

        [] →
            []


g : Int → String
g _ =
${ind(body, 4)}


main : Program
main = Node.print (g 0)
`;
  add(`rot.${k}.${k === 'dead' ? 'dead' : 'live'}`, main);
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const p of progs) {
  const d = path.resolve(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
