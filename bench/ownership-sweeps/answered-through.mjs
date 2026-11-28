// answered-through.mjs: the answer of a function parameter, read at each location of a large type (#2539).
//
//   node bench/ownership-sweeps/answered-through.mjs <outdir> [filter]
//
// A callee that is generic in its answer and answers what a function parameter answers has one wide
// location in its result. A caller that hands it its own function parameter reads that location at each
// of the N locations of its own type, and each of them holds every location of the answer. A call keeps
// the run of the first location for the others (kernel §8, *An expansion that reads nothing of its
// location is made once for a call's result*). The programs vary:
//   n       the constructors of the type, two lists each: 4 and 64 (the walk is in its budget with no
//           kept run), 256 (it is not)
//   via     through  `through f x = f x`
//           pick     the callee answers one of two calls of the function
//           both     the callee answers a pair of two answers
//           direct   the frame calls its function parameter itself
//   fn      fresh    the function makes new lists
//           captured the function is a closure that answers a list of the caller's
//   write   param    the frame pushes onto its own list parameter
//           answer   the frame pushes onto a list that it takes out of the answer
// Each has a dead twin (nothing is read after the call) and live twins: the list handed to the frame
// is read after, or the captured list is. A live twin that is accepted and written in place prints
// another output than the plain build or traps: `run.mjs` finds both.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
const filter = process.argv[3];
if (!out) {
  console.error('usage: node bench/ownership-sweeps/answered-through.mjs <outdir> [filter]');
  process.exit(2);
}

const sizes = [4, 64, 256];

const vias = {
  through: {
    decl: `through : (x → a), x → a
through f x = f x`,
    bind: (body) => `    t = through mk k
    u = through mk (k + 1)
${body}`,
  },
  pick: {
    decl: `pick : (x → a), x, x, Bool → a
pick f x y first = if first then f x else f y`,
    bind: (body) => `    t = pick mk k (k + 1) (k > 0)
    u = pick mk (k + 2) (k + 3) (k > 5)
${body}`,
  },
  both: {
    decl: `both : (x → a), x → a × a
both f x = ( f x, f x )`,
    bind: (body) => `    case both mk k of
        ( t, u ) →
${body.split('\n').map((l) => (l ? `        ${l}` : l)).join('\n')}`,
  },
  direct: {
    decl: '',
    bind: (body) => `    t = mk k
    u = mk (k + 1)
${body}`,
  },
};

const fns = {
  fresh: { arg: 'make', captures: false },
  captured: { arg: '(λk → C0 shared [ k ])', captures: true },
};

const writes = {
  param: `    List.push xs (size t + size u)`,
  answer: `    case t of
        C0 a b →
            List.push a (size u + List.length b + List.length xs)

        _ →
            xs`,
};

const twins = {
  dead: { after: '', needs: () => true },
  'handed.live': { after: ' ++ " / " ++ ints xs', needs: () => true },
  'captured.live': { after: ' ++ " / " ++ ints shared', needs: (fn) => fn.captures },
};

function program(n, viaName, fnName, writeName, twinName) {
  const via = vias[viaName];
  const fn = fns[fnName];
  const twin = twins[twinName];
  if (!twin.needs(fn)) return null;
  const ctors = Array.from({ length: n }, (_, i) => `C${i} (List Int) (List Int)`);
  const arms = Array.from({ length: n }, (_, i) => `        C${i} a b →\n            List.length a + List.length b`);
  return `import Node


type T
    = ${ctors.join('\n    | ')}


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


size : T → Int
size t =
    case t of
${arms.join('\n\n')}


make : Int → T
make k = C0 [ k ] [ k, k ]
${via.decl ? `\n\n${via.decl}\n` : ''}

run : (Int → T), Int, List Int → List Int
run mk k xs =
${via.bind(writes[writeName])}


main : Node.Program
main =
${fn.captures ? '    shared = [ 7, 8 ]\n' : ''}    xs = [ 1, 2 ]
    ys = run ${fn.arg} 3 xs
    Node.print (ints ys${twin.after})
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const n of sizes) {
  for (const via of Object.keys(vias)) {
    for (const fn of Object.keys(fns)) {
      for (const write of Object.keys(writes)) {
        for (const twin of Object.keys(twins)) {
          const name = `n${n}.${via}.${fn}.${write}.${twin}`;
          if (filter && !name.includes(filter)) continue;
          const src = program(n, via, fn, write, twin);
          if (src === null) continue;
          const d = path.join(out, name);
          fs.mkdirSync(d, { recursive: true });
          fs.writeFileSync(path.join(d, 'Main.beni'), src);
          list.push(d);
        }
      }
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
