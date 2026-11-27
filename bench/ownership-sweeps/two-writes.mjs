// two-writes.mjs: a callee that writes two locations of one argument (#2567).
//
//   node bench/ownership-sweeps/two-writes.mjs <outdir>
//
// A call whose callee writes two or more locations of an operand tests each write against the other
// locations of the operand (kernel §5, test 2), and reads each of them once for all the writes (kernel
// §8, *A call reads each location of an operand once*). The programs vary what the operand is, so that
// the read that the call keeps is of each kind of value:
//   kind    a constructor of two lists, a record of two lists, a tuple of two lists
//   shape   fresh    the operand is made in the call
//           named    it has a name
//           join     it is one of two values, by a condition
//           answer   it is the answer of a function that builds it
//           through  the writer is called by a function that hands its parameter on
//           nested   it is a part of a larger value, taken out by a pattern
//           twice    one list is at both of its places
//           cross    it is one of two values that hold the same two lists at other places
// Each has a dead twin (nothing of the operand is read after) and live twins (the first list, the
// second list, or the whole operand is read after the call). A live twin that is accepted and written
// in place prints another output than the plain build or traps: `run.mjs` finds both.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
if (!out) {
  console.error('usage: node bench/ownership-sweeps/two-writes.mjs <outdir>');
  process.exit(2);
}

const kinds = {
  ctor: {
    decl: 'type Two\n    = Two (List Int) (List Int)',
    type: 'Two',
    make: (a, b) => `Two ${a} ${b}`,
    write: `write : Two → Two
write t =
    case t of
        Two a b →
            Two (List.push a 1) (List.push b 2)`,
    show: `show : Two → String
show t =
    case t of
        Two a b →
            ints a ++ ";" ++ ints b`,
  },
  record: {
    decl: 'type alias Two =\n    a : List Int\n    b : List Int',
    type: 'Two',
    make: (a, b) => `{ a = ${a}, b = ${b} }`,
    write: `write : Two → Two
write t = { t | a = List.push t.a 1, b = List.push t.b 2 }`,
    show: `show : Two → String
show t = ints t.a ++ ";" ++ ints t.b`,
  },
  tuple: {
    decl: '',
    type: 'List Int × List Int',
    make: (a, b) => `( ${a}, ${b} )`,
    write: `write : List Int × List Int → List Int × List Int
write t =
    case t of
        ( a, b ) →
            ( List.push a 1, List.push b 2 )`,
    show: `show : List Int × List Int → String
show t =
    case t of
        ( a, b ) →
            ints a ++ ";" ++ ints b`,
  },
};

// Each shape: the lines before the call, the call, and whether the operand has the name `p`.
const shapes = {
  fresh: (k) => ({ pre: [], call: `write (${k.make('[ n ]', '[ n, n ]')})`, named: false, lists: false }),
  named: (k) => ({ pre: [`p = ${k.make('xs', 'ys')}`], call: 'write p', named: true, lists: true }),
  join: (k) => ({ pre: [], call: `write (if flag n then ${k.make('xs', 'ys')} else ${k.make('zs', 'ys')})`, named: false, lists: true }),
  answer: (k) => ({ pre: [], call: `write (mk xs ys)`, named: false, lists: true }),
  through: (k) => ({ pre: [], call: `go (${k.make('xs', 'ys')})`, named: false, lists: true }),
  nested: (k) => ({ pre: [`box = ( ${k.make('xs', 'ys')}, zs )`], call: 'write (first box)', named: false, lists: true }),
  twice: (k) => ({ pre: [], call: `write (${k.make('xs', 'xs')})`, named: false, lists: true }),
  cross: (k) => ({ pre: [], call: `write (if flag n then ${k.make('xs', 'ys')} else ${k.make('ys', 'xs')})`, named: false, lists: true }),
};

const twins = {
  dead: () => '',
  'first.live': () => ' ++ " / " ++ ints xs',
  'second.live': () => ' ++ " / " ++ ints ys',
  'whole.live': () => ' ++ " / " ++ show p',
};

function program(kindName, shapeName, twinName) {
  const k = kinds[kindName];
  const s = shapes[shapeName](k);
  if (twinName === 'whole.live' && !s.named) return null;
  if ((twinName === 'first.live' || twinName === 'second.live') && !s.lists) return null;
  const pre = s.pre.map((l) => `    ${l}\n`).join('');
  return `import Node


${k.decl}${k.decl ? '\n\n\n' : ''}ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


${k.show}


${k.write}


go : ${k.type} → ${k.type}
go t = write t


mk : List Int, List Int → ${k.type}
mk a b = ${k.make('a', 'b')}


first : (${k.type}) × List Int → ${k.type}
first box =
    case box of
        ( t, _ ) →
            t


flag : Int → Bool
flag n = Int.mod n 2 == 0


run : Int → String
run n =
    xs = [ n ]
    ys = [ n, n ]
    zs = [ 7 ]
${pre}    r = ${s.call}
    show r${twins[twinName]()}


main : Node.Program
main = Node.print (run 2 ++ " | " ++ run 3)
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const kind of Object.keys(kinds)) {
  for (const shape of Object.keys(shapes)) {
    for (const twin of Object.keys(twins)) {
      const src = program(kind, shape, twin);
      if (src === null) continue;
      const d = path.join(out, `${kind}.${shape}.${twin}`);
      fs.mkdirSync(d, { recursive: true });
      fs.writeFileSync(path.join(d, 'Main.beni'), src);
      list.push(d);
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
