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
//           page    a page of `platforms/browser-inline`, which chooses the checker v3: the group
//                   hands records on, and the caller updates the record that it answers (sizes up
//                   to 100). `run.mjs` builds it also as a user does, with no ownership flag
//   twin    dead    the caller reads none of the lists after
//           live    the caller reads after the write the two lists that its two runs write: the
//                   first, and the one that the group answers after three calls
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

// The list that `go 3` writes: the group's answer after three calls.
const third = (n, group) => (group === 'one' ? n - 3 : n - 2);

function page(n, group, live) {
  const names = Array.from({ length: n }, (_, i) => `a${i}`);
  const rot = [names[n - 1], ...names.slice(0, n - 1)];
  const type = `${Array.from({ length: n }, () => 'Cell').join(' × ')}, Int → Cell`;
  const fns = group === 'one'
    ? `r : ${type}
r ( ${names.join(', ')} ) k = if k == 0 then a0 else r ( ${rot.join(', ')} ) (k - 1)`
    : `r : ${type}
r ( ${names.join(', ')} ) k = if k == 0 then a0 else s ( ${rot.join(', ')} ) (k - 1)


s : ${type}
s ( ${names.join(', ')} ) k = if k == 0 then a1 else r ( ${rot.join(', ')} ) (k - 1)`;
  const lets = names.map((x, i) => `    ${x} = { v = ${i} }`).join('\n');
  const after = live ? ` ++ " / " ++ String.fromInt a0.v ++ " / " ++ String.fromInt a${third(n, group)}.v` : '';
  return `import Browser
import Html exposing (Html)
import Tea


type Msg
    = Add


type alias Cell =
    v : Int


type alias Model =
    out : String
    n : Int


${fns}


go : Int → String
go k =
${lets}
    l = r ( ${names.join(', ')} ) k
    m =
        { l
            | v = l.v + 9
        }
    String.fromInt m.v${after}


update : Msg, Model → Model
update msg model =
    case msg of
        Add →
            { model
                | out = go 3 ++ " ; " ++ go 0
                , n = model.n + 1
            }


view : Model → Html Msg
view model =
    <main id="outer">
        <button id="add" onClick={λ_ → Add}>add</button>
        <p id="state">{model.out}</p>
    </main>


main : Tea.Program
main =
    Browser.mountAt
        (Tea.sandbox { init = λ⊤ → { out = "", n = 0 }, update = update, view = view })
        "root"
`;
}

function program(n, group, write, live) {
  if (write === 'page') return page(n, group, live);
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
    ints l${live ? ` ++ " / " ++ ints a0 ++ " / " ++ ints a${third(n, group)}` : ''}


main : Node.Program
main = Node.print (go 3 ++ " ; " ++ go 0)
`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const n of sizes) {
  for (const group of ['one', 'two']) {
    for (const write of ['caller', 'inner', 'page']) {
      if (write === 'page' && n > 100) continue;
      for (const live of [false, true]) {
        const name = `n${n}.${group}.${write}.${live ? 'live' : 'dead'}`;
        if (filter && !name.includes(filter)) continue;
        const d = path.join(out, name);
        fs.mkdirSync(d, { recursive: true });
        fs.writeFileSync(path.join(d, 'Main.beni'), program(n, group, write, live));
        if (write === 'page') {
          fs.writeFileSync(path.join(d, 'PLATFORM'), 'platforms/browser-inline\n');
          fs.writeFileSync(path.join(d, 'steps'), 'element "root"\nclick #add\nclick #add\n');
        }
        list.push(d);
      }
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
