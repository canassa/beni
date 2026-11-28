// precision-153.mjs <outdir> [filter]: the acceptances of research report 153 crossed with live twins.
//
// `hoist.<place>.<read>.<twin>`: an update of a record handed as a parameter, then a read of the
// parameter after it (`ownership-v3-kernel.md` §11 item 10, *A read of a written field, read first*).
// `<place>` is where the update and the read stand; `<read>` what is read: `wx` the written field, `wy`
// another, `whole` the record, `alias` the written field through a `let` bound before the update. A
// read of the written field that the lowering reads first is accepted where the update runs on every
// path to it; every other reader of the old value is refused.
//
// `kept.<handler>.<twin>` (pages on `browser-inline`): a handler the runtime keeps captures the model
// (`ownership-v3-kernel.md` §6 rule 3, *A kept closure is observed only through its calls*); `update`
// writes `label`. `dead` handlers read other fields; `live` ones read `label` or hand the record on.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/precision-153.mjs <outdir> [filter]'); process.exit(2); }
const progs = [];
const add = (name, main, platform, steps) => { if (name.includes(filter)) progs.push({ name, main, platform, steps }); };

const HEAD = `import Node exposing (Program)
import String


type alias P =
    x : Int
    y : Int
    inner : { a : Int, b : Int }


show : P → String
show p = "\${String.fromInt p.x}/\${String.fromInt p.y}/\${String.fromInt p.inner.a}"


pair : P, Int → Int
pair q old = q.x * 100 + old


both : Bool, Bool → Bool
both a b = a && b
`;

// The read after the update, of the parameter `p` (or of `h`, bound to it before).
const READS = {
  wx: { e: 'p.x', twin: 'dead' },
  wy: { e: 'p.y', twin: 'dead' },
  inner: { e: 'p.inner.a', twin: 'dead' },
  whole: { e: '(String.length (show p))', twin: 'live' },
  alias: { e: 'h.x', twin: 'live' },
};

// Where the update and the read stand; `R` is the read. `ok`: the update runs on every path to the read.
const PLACES = {
  arg: { body: (R) => `h = p\npair { p | x = n } ${R}`, ok: true },
  let: { body: (R) => `h = p\nq = { p | x = n }\nq.x * 100 + ${R}`, ok: true },
  twice: { body: (R) => `h = p\nq = { p | x = n }\nr = { q | x = n + 1, y = q.y + 1 }\nr.x * 100 + r.y + ${R}`, ok: true },
  scrut: { body: (R) => `h = p\ncase { p | x = n } of\n    q →\n        q.x * 100 + ${R}`, ok: true },
  andl: { body: (R) => `h = p\nif both ((pair { p | x = n } 0) > 0) (${R} > 0) then ${R} else 0`, ok: true },
  arm: { body: (R) => `h = p\nq = if n > 0 then { p | x = n } else p\nq.x * 100 + ${R}`, ok: false },
  lam: { body: (R) => `h = p\nq = { p | x = n }\ng = λ⊤ → ${R}\nq.x * 100 + g ⊤`, ok: false },
  nested: { body: (R) => `h = p\nq = { p | inner = { (p.inner) | a = n } }\nq.inner.a * 100 + ${R}`, ok: true },
  pipe: { body: (R) => `h = p\n{ p | x = n } ▷ pair ${R}`, ok: true },
  inner2: { body: (R) => `h = p\nq = { p | x = n }\nr = { q | inner = { (q.inner) | b = n } }\nr.x * 100 + r.inner.b + ${R}`, ok: true },
  chain: { body: (R) => `h = p\nq = { p | inner = { a = n, b = n } }\nr = { (p.inner) | a = 77 }\nr.a * 100 + q.inner.a + ${R}`, ok: false },
};

for (const [pl, P] of Object.entries(PLACES)) for (const [rd, R] of Object.entries(READS)) {
  const ind = (s) => s.split('\n').map((l) => '    ' + l).join('\n');
  const main = `${HEAD}

f : P, Int → Int
f p n =
${ind(P.body(R.e))}


main : Program
main =
    Node.print "\${String.fromInt (f { x = 1, y = 2, inner = { a = 3, b = 4 } } 5)} \${String.fromInt (f { x = 6, y = 7, inner = { a = 8, b = 9 } } 0)}"
`;
  // `nested` and `chain` write `inner`, not `x`: there `alias` (`h.x`) is dead and `inner` live.
  const twin = (pl === 'nested' || pl === 'chain') && rd === 'alias' ? 'dead' : pl === 'chain' && rd === 'inner' ? 'live' : R.twin;
  add(`hoist.${pl}.${rd}.${twin}`, main);
}

// Handlers the markup runtime keeps, each capturing the model.
const HANDLERS = {
  id: { h: 'λ_ → Pick model.id', twin: 'dead' },
  idlet: { h: 'λ_ →\n                    i = model.id\n                    Pick i', twin: 'dead' },
  label: { h: 'λ_ → Pick (String.length model.label)', twin: 'live' },
  whole: { h: 'λ_ → Pick (String.length (shown model))', twin: 'live' },
  joined: { h: 'if model.n > 1 then λ_ → Pick model.id else λ_ → Pick (String.length model.label)', twin: 'live' },
  inner: { h: 'λ_ → Pick ((λ⊤ → model.id) ⊤)', twin: 'dead' },
  innerl: { h: 'λ_ → Pick ((λ⊤ → String.length model.label) ⊤)', twin: 'live' },
  msg: { h: 'λ_ → Keep model', twin: 'live' },
};
for (const [k, H] of Object.entries(HANDLERS)) {
  const main = `import Browser
import Html exposing (Html)
import Tea


type Msg
    = Pick Int
    | Keep Model
    | Rename


type alias Model =
    id : Int
    label : String
    picked : Int
    n : Int


shown : Model → String
shown m = "\${String.fromInt m.id}:\${m.label}"


update : Msg, Model → Model
update msg model =
    case msg of
        Pick i →
            { model | picked = i }

        Keep m →
            { model | picked = String.length m.label }

        Rename →
            { model | label = "row \${String.fromInt model.n}", n = model.n + 1 }


view : Model → Html Msg
view model =
    <main>
        <button id="pick" onClick={${H.h}}>pick</button>
        <button id="rename" onClick={Rename}>rename</button>
        <p id="label">{model.label}</p>
        <p id="picked">{model.picked}</p>
    </main>


main : Tea.Program
main =
    Browser.mountAt
        (Tea.sandbox { init = λ⊤ → { id = 4, label = "row 0", picked = 0, n = 1 }, update = update, view = view })
        "root"
`;
  add(`kept.${k}.${H.twin}`, main, 'platforms/browser-inline', 'element "root"\nclick #rename\nclick #pick\nclick #rename\nclick #rename\nclick #pick\n');
}

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const p of progs) {
  const d = path.resolve(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'Main.beni'), p.main);
  if (p.platform) fs.writeFileSync(path.join(d, 'PLATFORM'), `${p.platform}\n`);
  if (p.steps) fs.writeFileSync(path.join(d, 'steps'), p.steps);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
