// rotations.mjs: a recursive group whose contract takes as many rounds as its tuple has positions (#2513).
//
//   node bench/ownership-sweeps/rotations.mjs <outdir> [filter]
//
// A function that hands its `n` lists on, one place round, each time it calls itself answers any of
// them, and its contract finds one more of them in each round of its group (kernel §3.3 item 9).
// The rounds of a group have no bound of their own; the budget of its members is their bound. The
// programs vary the size and the group, and a caller writes the list that the group answers:
//   n       the positions: 4, 32 and 64 (at most 64 rounds), and 66, 70, 100, 150 and 200 (more)
//   group   one     one function that calls itself
//           two     two functions that call each other, each handing the lists on one place round
//   write   caller  the caller pushes onto the list that the group answers
//           inner   the group pushes onto the list that it answers, where the count is 0
//   twin    dead    the caller reads none of the lists after
//           live    the caller reads one of the lists after (one at an even place, which each
//                   group can answer and write)
// A live twin that is accepted and written in place prints another output than the plain build or
// traps: `run.mjs` finds both.
import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
const filter = process.argv[3];
if (!out) {
  console.error('usage: node bench/ownership-sweeps/rotations.mjs <outdir> [filter]');
  process.exit(2);
}

const sizes = [4, 32, 64, 66, 70, 100, 150, 200];

function program(n, group, write, live) {
  const names = Array.from({ length: n }, (_, i) => `a${i}`);
  const rot = [names[n - 1], ...names.slice(0, n - 1)];
  const type = `${Array.from({ length: n }, () => 'List Int').join(' × ')}, Int → List Int`;
  const last = write === 'inner' ? 'List.push a0 9' : 'a0';
  const fns = group === 'one'
    ? `r : ${type}
r ( ${names.join(', ')} ) k = if k == 0 then ${last} else r ( ${rot.join(', ')} ) (k - 1)`
    : `r : ${type}
r ( ${names.join(', ')} ) k = if k == 0 then ${last} else s ( ${rot.join(', ')} ) (k - 1)


s : ${type}
s ( ${names.join(', ')} ) k = if k == 0 then a1 else r ( ${rot.join(', ')} ) (k - 1)`;
  const lets = names.map((x, i) => `    ${x} = [ ${i} ]`).join('\n');
  const answer = write === 'caller' ? '    l = List.push (r ( ' + names.join(', ') + ' ) k) 9' : '    l = r ( ' + names.join(', ') + ' ) k';
  return `import Node


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


${fns}


go : Int → String
go k =
${lets}
${answer}
    ints l${live ? ` ++ " / " ++ ints a${n - 2}` : ''}


main : Node.Program
main = Node.print (go 3 ++ " ; " ++ go 0)
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const n of sizes) {
  for (const group of ['one', 'two']) {
    for (const write of ['caller', 'inner']) {
      for (const live of [false, true]) {
        const name = `n${n}.${group}.${write}.${live ? 'live' : 'dead'}`;
        if (filter && !name.includes(filter)) continue;
        const d = path.join(out, name);
        fs.mkdirSync(d, { recursive: true });
        fs.writeFileSync(path.join(d, 'Main.beni'), program(n, group, write, live));
        list.push(d);
      }
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
