// evaluation-order.mjs: research report 114 §7. One read and one write of the list `q`, in two parts of one
// construct that JavaScript evaluates in a known order (`language.md` §6, *Evaluation order*). The checker must
// reason in that order: a read that runs after the write sees the change, and one that runs before does not.
//
//   node bench/ownership-sweeps/evaluation-order.mjs <outdir> [filter]
//
// A program is `order.<construct>.<dir>.<write>.<read>.<twin>`:
//
// - `construct`: where the two parts are (below). `first` is the part that runs first, `second` the other.
// - `dir`: `wr`, the write runs first and the read second; `rw`, the read runs first.
// - `write`: `set` (`List.set q 0 9`) or `push` (`List.push q 9`). The part shows the answer.
// - `read`: `show` (`show q`) or `len` (`List.length q`).
// - `twin`: for `wr`, `live` reads `q` and `dead` reads `[ 4 ]` instead; for `rw`, `none`: the read runs before
//   the write, so the program is safe (a refusal of it is a precision loss).
//
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/evaluation-order.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const HEAD = 'import List\nimport Maybe\nimport Node exposing (Program)\nimport String\n';
const MARKUP_HEAD = 'import Html exposing (Html)\nimport List\nimport Maybe\nimport Node\nimport Ssr\nimport String\n';
const HELPERS = `show : List Int → String
show l =
    String.join (List.map l String.fromInt) ","


cat : String, String → String
cat a b =
    a ++ "/" ++ b


mk : String → { f : String → String }
mk s =
    { f = λt → s ++ "/" ++ t }


mkf : String → (String → String)
mkf s =
    λt → s ++ "/" ++ t


mkT : String → (String → String) × Int
mkT s =
    ( λt → s ++ "/" ++ t, 1 )


type P
    = P String String


type alias R =
    { z : String, a : String }
`;

// A construct: `body(X, Y)` is the lines of `go` after `q = [ n, 2 ]`, where `X` runs before `Y`. Both are
// `String` expressions. `fns`: more declarations. `maybe`: the body is that of a `Maybe String` function.
// `list`: `X` and `Y` are a `List Int` and an `Int` expression instead (a list's own operations).
const C = {
  callArgs: { body: (x, y) => `cat (${x}) (${y})` },
  ctorArgs: { body: (x, y) => `case P (${x}) (${y}) of\n    P a b →\n        a ++ "/" ++ b` },
  aliasCtor: { body: (x, y) => `r = R (${x}) (${y})\nr.z ++ "/" ++ r.a` },
  tuple: { body: (x, y) => `t = ( ${x}, ${y} )\nt.0 ++ "/" ++ t.1` },
  listLit: { body: (x, y) => `String.join [ ${x}, ${y} ] "/"` },
  record: { body: (x, y) => `r = { z = ${x}, a = ${y} }\nr.z ++ "/" ++ r.a` },
  update: { body: (x, y) => `base = { z = "", a = "" }\nr = { base | z = ${x}, a = ${y} }\nr.z ++ "/" ++ r.a` },
  updateRev: { body: (x, y) => `base = { z = "", a = "" }\nr = { base | a = ${x}, z = ${y} }\nr.z ++ "/" ++ r.a` },
  interp: { body: (x, y) => `"\${${x}}/\${${y}}"` },
  append: { body: (x, y) => `(${x}) ++ "/" ++ (${y})` },
  eq: { body: (x, y) => `if (${x}) == (${y}) then "eq" else "ne"` },
  less: { body: (x, y) => `if (${x}) < (${y}) then "lt" else "ge"` },
  and: { body: (x, y) => `if String.length (${x}) > 0 && String.length (${y}) > 0 then "both" else "not"` },
  caseScrut: { body: (x, y) => `case ${x} of\n    s →\n        s ++ "/" ++ (${y})` },
  caseTuple: { body: (x, y) => `case ( ${x}, ${y} ) of\n    ( a, b ) →\n        a ++ "/" ++ b` },
  ifCond: { body: (x, y) => `if String.length (${x}) > 0 then\n    ${y}\n\nelse\n    "-"` },
  letBody: { body: (x, y) => `s = ${x}\ns ++ "/" ++ (${y})` },
  letTwo: { body: (x, y) => `s = ${x}\nt = ${y}\ns ++ "/" ++ t` },
  letPattern: { body: (x, y) => `( s, k ) = ( ${x}, 1 )\ns ++ "/" ++ (${y}) ++ String.fromInt k` },
  lambdaArg: { body: (x, y) => `(λs → s ++ "/" ++ (${y})) (${x})` },
  computedCallee: { body: (x, y) => `(mkf (${x})) (${y})` },
  pipeArg: { body: (x, y) => `(${x}) ▷ cat (${y})` },
  pipeField: { body: (x, y) => `(${y}) ▷ (mk (${x})).f` },
  pipeIf: { body: (x, y) => `(${y}) ▷ (if n == 0 then mkf (${x}) else mkf "")` },
  pipeCase: { body: (x, y) => `(${y})\n    ▷ (case n of\n            0 →\n                mkf (${x})\n\n            _ →\n                mkf ""\n      )` },
  pipeTuple: { body: (x, y) => `(${y}) ▷ (mkT (${x})).0` },
  pipeBack: { body: (x, y) => `(mk (${x})).f ◁ (${y})` },
  fieldOfCall: { body: (x, y) => `(mk (${x})).f (${y})` },
  tryArg: { maybe: true, body: (x, y) => `s = (Just (${x}))?\nJust (s ++ "/" ++ (${y}))` },
  tryInCall: { maybe: true, body: (x, y) => `Just (cat ((Just (${x}))?) (${y}))` },
  tryAfter: { maybe: true, body: (x, y) => `Just (cat (${x}) ((Just (${y}))?))` },
  markup: { markup: true, body: (x, y) => `Ssr.render (<p>{${x}}{${y}}</p>)` },
  // A list's own operations: `X` is a `List Int` expression, `Y` an `Int` one.
  spread: { list: true, body: (x, y) => `show [ …(${x}), ${y} ]` },
  spreadRev: { list: true, rev: true, body: (x, y) => `show [ ${x}, …(${y}) ]` },
  listAppend: { list: true, body: (x, y) => `show ((${x}) ++ [ ${y} ])` },
  method: { list: true, body: (x, y) => `show ((${x}).append [ ${y} ])` },
  methodPipe: { list: true, body: (x, y) => `show ([ ${y} ] ▷ (${x}).append)` },
  listAppendRev: { list: true, rev: true, body: (x, y) => `show ([ ${x} ] ++ (${y}))` },
  methodRev: { list: true, rev: true, body: (x, y) => `show ([ ${x} ].append (${y}))` },
  methodPipeRev: { list: true, rev: true, body: (x, y) => `show ((${y}) ▷ [ ${x} ].append)` },
  // `For` reads its list where the page renders, after each hole: the write in the hole runs first.
  markupFor: { markup: true, forRead: true, body: (x, y) => `Ssr.render (<div><ul><For each={${y.includes('[ 4 ]') ? '[ 4 ]' : 'q'}}>{λi → <li>{String.fromInt i}</li>}</For></ul>{${x}}</div>)` },
};

const WRITES = { set: 'List.set q 0 9', push: 'List.push q 9' };
const READS = { show: (s) => `show ${s}`, len: (s) => `String.fromInt (List.length ${s})` };

function gen(cname, dir, wname, rname, twin) {
  const c = C[cname];
  const src = twin === 'dead' ? '[ 4 ]' : 'q';
  let w;
  let r;
  if (c.list) {
    // The list part is the write; the `Int` part is the read. `rev`: the `Int` part comes first.
    w = WRITES[wname];
    r = rname === 'len' ? `List.length ${src}` : `Maybe.withDefault (List.get ${src} 0) 7`;
    const [first, second] = dir === 'wr' ? [w, r] : [r, w];
    // Only one order fits each list form; the other direction swaps the roles where the types allow.
    if (!c.rev && dir === 'rw') return null;
    if (c.rev && dir === 'wr') return null;
    const body = c.body(first, second);
    return program(HEAD, HELPERS, `go : Int → String\ngo n =\n    q = [ n, 2 ]\n${ind(body, 4)}\n`, 'main : Program\nmain =\n    Node.print (go 0)\n');
  }
  // `For` reads at the render, after every hole: only the write can run first.
  if (c.forRead && dir === 'rw') return null;
  w = `show (${WRITES[wname]})`;
  r = READS[rname](src);
  const [x, y] = dir === 'wr' ? [w, r] : [r, w];
  const body = c.body(x, y);
  if (c.maybe) {
    return program(HEAD, HELPERS, `goM : Int → Maybe String\ngoM n =\n    q = [ n, 2 ]\n${ind(body, 4)}\n\n\ngo : Int → String\ngo n =\n    Maybe.withDefault (goM n) "-"\n`, 'main : Program\nmain =\n    Node.print (go 0)\n');
  }
  if (c.markup) {
    return program(MARKUP_HEAD, HELPERS, `go : Int → String\ngo n =\n    q = [ n, 2 ]\n${ind(body, 4)}\n`, 'main : Node.Program\nmain =\n    Node.print (go 0)\n');
  }
  return program(HEAD, HELPERS, `go : Int → String\ngo n =\n    q = [ n, 2 ]\n${ind(body, 4)}\n`, 'main : Program\nmain =\n    Node.print (go 0)\n');
}

const program = (...parts) => parts.filter(Boolean).join('\n\n');

const names = [];
fs.mkdirSync(out, { recursive: true });
for (const cname of Object.keys(C)) {
  for (const dir of ['wr', 'rw']) {
    for (const wname of Object.keys(WRITES)) {
      for (const rname of Object.keys(READS)) {
        for (const twin of dir === 'wr' ? ['live', 'dead'] : ['none']) {
          const name = `order.${cname}.${dir}.${wname}.${rname}.${twin}`;
          if (!name.includes(filter)) continue;
          const src = gen(cname, dir, wname, rname, twin);
          if (src === null) continue;
          const dirp = path.join(out, name);
          fs.mkdirSync(dirp, { recursive: true });
          fs.writeFileSync(path.join(dirp, 'Main.beni'), src);
          names.push(path.resolve(dirp));
        }
      }
    }
  }
}
fs.writeFileSync(path.join(out, 'LIST'), names.join('\n') + '\n');
console.log(`${names.length} programs in ${out}`);
