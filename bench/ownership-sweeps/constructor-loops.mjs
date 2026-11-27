// constructor-loops.mjs: a loop over a `case` of n constructors with two lists each (#2567).
//
//   node bench/ownership-sweeps/constructor-loops.mjs <outdir>
//
// `step` moves the two lists of a constructor to the next one and swaps them, with a push onto each;
// `loop` applies it `k` times. The contract of `loop` takes as many rounds as the cycle of the 2n list
// positions is long (n where n is even, 2n where it is odd), and each round's call writes all 2n
// positions of its argument. Before #2567 each of these writes read every other position again, and the
// walk passed its budget at 11 constructors and from 13 on. With one read of each position for a call's
// writes, it is judged at 11, 12, 14 and 16, and passes its budget at 13, 15 and from 17 on.
//
// Each size has dead and live twins, by what the program holds of the argument and reads after the
// loop:
//   fresh.dead   the argument is made in the call: nothing else holds its lists
//   kept.dead    a list of the argument has a name that no line reads after
//   kept.live    the name is read after the loop: an edit in place of that list is seen
//   twice.live   one list is at both places of the argument: the two pushes of a step write one array
//   answer.live  the argument is the answer of a function that answers its parameter, read after
// A live twin that is accepted and edited in place prints another output than the plain build (DIFF) or
// traps under `--sanitize-lists` (TRAP): `run.mjs` finds both.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
if (!out) {
  console.error('usage: node bench/ownership-sweeps/constructor-loops.mjs <outdir>');
  process.exit(2);
}

function program(n, twin, start, steps) {
  const ctors = Array.from({ length: n }, (_, i) => `C${i} (List Int) (List Int)`);
  const arms = Array.from({ length: n }, (_, i) => `        C${i} a b →\n            C${(i + 1) % n} (List.push b ${i}) (List.push a ${i})\n`);
  const shows = Array.from({ length: n }, (_, i) => `        C${i} a b →\n            "C${i} " ++ ints a ++ " ; " ++ ints b\n`);
  const main = {
    'fresh.dead': `main = Node.print (show (loop (C${start} [ 1 ] [ 2, 3 ]) ${steps}))`,
    'kept.dead': `main =\n    xs = [ 1 ]\n    r = loop (C${start} xs [ 2, 3 ]) ${steps}\n    Node.print (show r)`,
    'kept.live': `main =\n    xs = [ 1 ]\n    r = loop (C${start} xs [ 2, 3 ]) ${steps}\n    Node.print (show r ++ " / " ++ ints xs)`,
    'twice.live': `main =\n    xs = [ 1 ]\n    r = loop (C${start} xs xs) ${steps}\n    Node.print (show r)`,
    'answer.live': `main =\n    t = C${start} [ 1 ] [ 2, 3 ]\n    r = loop (same t) ${steps}\n    Node.print (show r ++ " / " ++ show t)`,
  }[twin];
  return `import Node


type T
    = ${ctors.join('\n    | ')}


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


same : T → T
same t = t


step : T → T
step t =
    case t of
${arms.join('\n')}

loop : T, Int → T
loop t k = if k ≤ 0 then t else loop (step t) (k - 1)


show : T → String
show t =
    case t of
${shows.join('\n')}

main : Node.Program
${main}
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const n of [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 13, 14, 15, 16, 18, 20, 24]) {
  for (const twin of ['fresh.dead', 'kept.dead', 'kept.live', 'twice.live', 'answer.live']) {
    for (const [start, steps] of [[0, 3], [n - 1, 2 * n + 1]]) {
      const d = path.join(out, `n${n}.s${start}.k${steps}.${twin}`);
      fs.mkdirSync(d, { recursive: true });
      fs.writeFileSync(path.join(d, 'Main.beni'), program(n, twin, start, steps));
      list.push(d);
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
