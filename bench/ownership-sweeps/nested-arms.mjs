// nested-arms.mjs <outdir> [filter]: a generator for the cost of a cell's versions across nested arms
// (#2599, kernel §8 and §13 item 6). One function nests a two-armed `if` or `case` `depth` deep, the whole
// rest of the nesting in each arm, so the program has 2^depth ways through it; each arm writes the cell or
// reads it. The join of each level is a join of the joins below it. Before #2599 the readings of those joins
// were made again at each call, uncounted: depth 8 took 4.4 GB, depth 9 ran out of memory. Each program must
// end in a verdict or a limit, in seconds and in little memory, and an accepted write must print what the
// plain build prints.
//
// Programs are `<depth>.<form>.<cell>.<op>.<wrap>.<twin>/Main.beni`:
//
// - depth: 1 to 10 levels (10 is 5 000 lines and more);
// - form: `if` (`if flag i then … else …`) or `case` (`case pick i of 0 → …; _ → …`);
// - cell: `made` (the function makes its cell) or `param` (`main` makes it and hands it);
// - op: `write` (the first arm pushes in place with `Ref.update`, the second stores a new list with
//   `Ref.set`) or `read` (the first arm logs the contents, the second logs a string);
// - wrap: `none` (the nesting is the function's body) or `local` (a local function that captured the
//   cell runs the nesting, and the function calls it once: kernel §13 item 11);
// - twin: `dead` (nothing old is read), `live` (a loan taken before the nesting is read after it) or
//   `liveArm` (each first arm takes a loan, writes or reads, and logs the loan).
//
// A `write` program with a `live` or `liveArm` twin reads a loan after an in-place write of the list it
// holds: the checker must refuse it, or the outputs must agree. Every other program is safe. Each log
// line goes to `Debug.log` (`Log.withSink`), so the output is the same in every run.
import fs from 'node:fs';
import path from 'node:path';

const [out, filter] = process.argv.slice(2);
if (!out) {
  console.error('usage: node bench/ownership-sweeps/nested-arms.mjs <outdir> [filter]');
  process.exit(2);
}

const head = `import Debug
import Io
import List
import Log exposing (Entry)
import Node exposing (Program)
import Ref exposing (Ref)
import String


ints : List Int → String
ints xs = String.join (List.map xs String.fromInt) ","


flag : Int → Bool
flag n = Int.mod n 3 == 0


pick : Int → Int
pick n = Int.mod n 3


sink : Entry → ⊤
sink entry = Debug.log entry.message ⊤

`;

function arms(op, twin, i) {
  const loan = twin === 'liveArm';
  const first = op === 'write' ? [`Ref.update c λl → List.push l ${i}`] : [`Log.info (ints (Ref.get c))`];
  const second = op === 'write' ? [`Ref.set c [ ${i} ]`] : [`Log.info "${i}"`];
  return [loan ? [`o${i} = Ref.get c`, ...first, `Log.info (ints o${i})`] : first, second];
}

function nest(depth, form, op, twin, i, ind) {
  if (i === depth) return [`${ind}Log.info "end"`];
  const [a, b] = arms(op, twin, i);
  const inner = (body, at) => [...body.map((l) => `${at}${l}`), ...nest(depth, form, op, twin, i + 1, at)];
  if (form === 'if') {
    return [`${ind}if flag ${i} then`, ...inner(a, `${ind}    `), `${ind}else`, ...inner(b, `${ind}    `)];
  }
  return [`${ind}case pick ${i} of`, `${ind}    0 →`, ...inner(a, `${ind}        `), `${ind}    _ →`, ...inner(b, `${ind}        `)];
}

function program(depth, form, cell, op, wrap, twin) {
  const lines = [];
  const sig = cell === 'made' ? 'go : ⊤ → String' : 'go : Ref (List Int) → String';
  lines.push(sig, cell === 'made' ? 'go ⊤ =' : 'go c =');
  if (cell === 'made') lines.push('    c = Ref.make [ 0 ]');
  if (twin === 'live') lines.push('    old = Ref.get c');
  if (wrap === 'local') {
    lines.push('    run ⊤ =', ...nest(depth, form, op, twin, 0, '        '), '    run ⊤');
  } else {
    lines.push(...nest(depth, form, op, twin, 0, '    '));
  }
  lines.push(twin === 'live' ? '    ints old ++ ";" ++ ints (Ref.get c)' : '    ints (Ref.get c)');
  const main = cell === 'made'
    ? 'main = Io.run λ⊤ → Node.print (Log.withSink sink go)'
    : 'main = Io.run λ⊤ →\n    c = Ref.make [ 0 ]\n    Node.print (Log.withSink sink λ⊤ → go c)';
  return `${head}\n${lines.join('\n')}\n\n\nmain : Program\n${main}\n`;
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (let depth = 1; depth <= 10; depth++) {
  for (const form of ['if', 'case']) for (const cell of ['made', 'param']) for (const op of ['write', 'read'])
    for (const wrap of ['none', 'local']) for (const twin of ['dead', 'live', 'liveArm']) {
      const name = `${depth}.${form}.${cell}.${op}.${wrap}.${twin}`;
      if (filter && !name.includes(filter)) continue;
      const d = path.join(out, name);
      fs.mkdirSync(d, { recursive: true });
      fs.writeFileSync(path.join(d, 'Main.beni'), program(depth, form, cell, op, wrap, twin));
      list.push(path.resolve(d));
    }
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
