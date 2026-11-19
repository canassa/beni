// dicts.mjs <outdir> [filter]: a generator for dictionaries written in place (research report 160).
// A program makes a dictionary `d0 : Dict Int (List Int)` (keys 1 and 2), keeps it in a holder, writes
// it (a writer of core's `Dict`, a helper, a helper of another module, a fold, an update whose callback
// writes the value, a get then an insert), then reads the holder. In place the holder and the written
// dictionary are one storage, and a value written in place is one list: a read after the write sees
// the new entries, so the checker must refuse it or the outputs must agree. Programs are
// `<maker>.<holder>.<writer>.<read>.<twin>/Main.beni`: `dead` when nothing reads the holder after
// the write, `live` otherwise. A refusal of a `dead` twin is a precision loss; a TRAP or DIFF of any
// is a soundness hole. The `set.…` programs do the same with a `Set Int`. See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/dicts.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

// Where `d0` comes from. `arg`: `main` makes it and hands it to `go`; otherwise `go` makes it.
const MAKERS = {
  fromList: { e: 'Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]' },
  inserts: { e: 'Dict.insert (Dict.insert (Dict.empty ⊤) 1 [ 1 ]) 2 [ 2 ]' },
  fold: { e: 'List.foldl [ 1, 2 ] (Dict.empty ⊤) λk acc → Dict.insert acc k [ k ]' },
  map: { e: 'Dict.map (Dict.fromList [ ( 1, 1 ), ( 2, 2 ) ]) λ_ v → [ v ]' },
  shared: { e: 'Dict.insert (Dict.insert (Dict.empty ⊤) 1 one) 2 one', pre: 'one = [ 1 ]' },
  arg: { e: 'd', arg: 'Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]' },
  top: { e: 'd', arg: 'base' },
};

// Where the old dictionary stays, and how it is read back after the write.
const HOLDERS = {
  name: { pre: '', get: 'd0' },
  alias: { pre: 'h = d0', get: 'h' },
  tuple: { pre: 'h = ( d0, 1 )', get: 'fstOf h' },
  field: { pre: 'h = { inner = d0 }', get: 'h.inner' },
  ctor: { pre: 'h = Just d0', get: 'Maybe.withDefault h d0' },
  list: { pre: 'h = [ d0 ]', get: 'Maybe.withDefault (List.head h) d0' },
  closure: { pre: 'h = λ⊤ → d0', get: 'h ⊤' },
  outer: { pre: 'h = Dict.singleton 0 d0', get: 'Maybe.withDefault (Dict.get h 0) d0' },
};

// How `d0` is written: an expression that answers the written dictionary.
const WRITERS = {
  insNew: 'Dict.insert d0 3 [ 30 ]',
  insOld: 'Dict.insert d0 1 [ 11 ]',
  remove: 'Dict.remove d0 1',
  swap: 'Dict.swap d0 1 2',
  insertAt: 'Dict.insertAt d0 0 4 [ 40 ]',
  sortBy: 'Dict.sortBy d0 λk _ → 0 - k',
  updJust: 'Dict.update d0 2 λ_ → Just [ 7 ]',
  updNothing: 'Dict.update d0 1 λ_ → Nothing',
  updPush: 'Dict.update d0 1 λm → Maybe.map m λxs → List.push xs 5',
  getPush: 'case Dict.get d0 1 of\n    Just xs →\n        Dict.insert d0 1 (List.push xs 5)\n\n    Nothing →\n        d0',
  helper: 'bump d0',
  other: 'Other.bump d0',
  fold: 'List.foldl [ 5, 6 ] d0 λk acc → Dict.insert acc k [ k ]',
};

// What is read of the holder after the write, `g` the dictionary read back.
const READS = {
  none: null,
  size: (g) => `String.fromInt (Dict.size ${g})`,
  keys: (g) => `String.join (List.map (Dict.keys ${g}) String.fromInt) ","`,
  whole: (g) => `render ${g}`,
  value1: (g) => `ints (Maybe.withDefault (Dict.get ${g} 1) [])`,
  value2: (g) => `ints (Maybe.withDefault (Dict.get ${g} 2) [])`,
};

const OTHER = `import Dict exposing (Dict)


pub bump : Dict Int (List Int) → Dict Int (List Int)
bump d = Dict.insert d 3 [ 30 ]
`;

const COMMON = `ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


render : Dict Int (List Int) → String
render d = String.join (List.map (Dict.toList d) λ( k, v ) → "\${String.fromInt k}=\${ints v}") ";"


fstOf : a × Int → a
fstOf ( a, _ ) = a


bump : Dict Int (List Int) → Dict Int (List Int)
bump d = Dict.insert d 3 [ 30 ]


base : Dict Int (List Int)
base = Dict.fromList [ ( 1, [ 1 ] ), ( 2, [ 2 ] ) ]
`;

function gen(maker, holder, writer, read) {
  const m = MAKERS[maker];
  const h = HOLDERS[holder];
  const lines = [];
  if (m.pre) lines.push(m.pre);
  lines.push(`d0 = ${m.e}`);
  if (h.pre) lines.push(h.pre);
  lines.push(`d1 =\n${ind(WRITERS[writer], 4)}`);
  const shown = ['render d1'];
  if (READS[read]) shown.push(READS[read](/ /.test(h.get) ? `(${h.get})` : h.get));
  lines.push(`[ ${shown.join(', ')} ]`);
  const param = m.arg ? 'd' : '_';
  const go = `go : Dict Int (List Int) → List String\ngo ${param} =\n${ind(lines.join('\n'), 4)}\n`;
  const arg = m.arg ? (/ /.test(m.arg) ? `(${m.arg})` : m.arg) : '(Dict.empty ⊤)';
  return `import Dict exposing (Dict)\nimport Node exposing (Program)\nimport Other\n\n\n${COMMON}\n\n${go}\n\nmain : Program\nmain = Node.printLines (go ${arg})\n`;
}

// A `Set Int` kept and written: the same, with a set's writers and reads.
const SET_WRITERS = { insNew: 'Set.insert s0 3', remove: 'Set.remove s0 1', swap: 'Set.swap s0 1 2', sortBy: 'Set.sortBy s0 λk → 0 - k', insertAt: 'Set.insertAt s0 0 4' };
const SET_READS = { none: null, size: (g) => `String.fromInt (Set.size ${g})`, members: (g) => `String.join (List.map (Set.toList ${g}) String.fromInt) ","`, member: (g) => `if Set.member ${g} 1 then "yes" else "no"` };
const SET_HOLDERS = { name: { pre: '', get: 's0' }, tuple: { pre: 'h = ( s0, 1 )', get: 'fstOf h' }, field: { pre: 'h = { inner = s0 }', get: 'h.inner' } };
function genSet(holder, writer, read) {
  const h = SET_HOLDERS[holder];
  const lines = ['s0 = Set.fromList [ 1, 2 ]'];
  if (h.pre) lines.push(h.pre);
  lines.push(`s1 = ${SET_WRITERS[writer]}`);
  const shown = ['String.join (List.map (Set.toList s1) String.fromInt) ","'];
  if (SET_READS[read]) shown.push(SET_READS[read](/ /.test(h.get) ? `(${h.get})` : h.get));
  lines.push(`[ ${shown.join(', ')} ]`);
  return `import Node exposing (Program)\nimport Set exposing (Set)\n\n\nfstOf : a × Int → a\nfstOf ( a, _ ) = a\n\n\ngo : ⊤ → List String\ngo ⊤ =\n${ind(lines.join('\n'), 4)}\n\n\nmain : Program\nmain = Node.printLines (go ⊤)\n`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
const emit = (name, files) => {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, text] of Object.entries(files)) fs.writeFileSync(path.join(d, f), text);
  list.push(path.resolve(d));
};
for (const maker of Object.keys(MAKERS)) for (const holder of Object.keys(HOLDERS)) for (const writer of Object.keys(WRITERS)) for (const read of Object.keys(READS)) {
  emit(`${maker}.${holder}.${writer}.${read}.${READS[read] ? 'live' : 'dead'}`, { 'Main.beni': gen(maker, holder, writer, read), 'Other.beni': OTHER });
}
for (const holder of Object.keys(SET_HOLDERS)) for (const writer of Object.keys(SET_WRITERS)) for (const read of Object.keys(SET_READS)) {
  emit(`set.${holder}.${writer}.${read}.${SET_READS[read] ? 'live' : 'dead'}`, { 'Main.beni': genSet(holder, writer, read) });
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
