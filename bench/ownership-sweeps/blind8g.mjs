// blind8g.mjs <outdir> [filter]: research report 128, an eighth blind test (reader G).
//
// Families, each a program per name `<family>.<case>...<twin>/`:
//
// - `schema`: program code that a `schema` declaration names in a `via` conversion. The compiled
//   parse and print workers call it with the program's values, and no walked body calls it. The
//   function writes the list it is handed (`push`, `set`, `update`, `insertAt`, `pop`); it is named in
//   the declaration as a top-level function, a function of another module, a partial application, or
//   a lambda (the lambda's body is not walked, so it writes nothing in place), or the conversion is a
//   top-level value (walked: refused). The caller prints a value and reads it after (`live`) or not
//   (`dead`); one case parses instead. The same on `browser-tea`, where `update` prints the model.
// - `page`: The Elm Architecture on `browser` and `browser-tea` whose `update` writes model lists in
//   place, viewed through a positional `For`, a row helper, a row with its index, a nested `For`, a
//   class list, a helper that answers markup, and an arm with a `let`; `browser-inline` through text,
//   length and head holes and a nested record. These test the platform rule (`boundary.md` §9.4.8).
// - `cell`: `Task.bracket`, `onExit`, `defer`, `spawn`, `Ref.update` and `modify`, `Queue`, `Dict`
//   holders of a list that is then written.
// - `type`: a non-regular type (`Nest a = Flat a | Deep (Nest (List a))`), a row inside a recursive
//   type, `Rose a` with `a = List Int`.
// - `maker`: one list at many places of a list, made by 18 functions of `core/`, then one element written.
// - `slow`: shapes whose check is slow: the entry's largest solution over a model whose `update` shifts
//   `n` list fields (`BLIND8G_FIELDS`, default 200), and a recursive function whose contract grows by
//   one field a round while each round walks a heavy body (`BLIND8G_ROUNDS`, default 30 fields).
//   `BLIND8G_FIELDS=800` takes about 19 s to check, `BLIND8G_ROUNDS=60` about 6 s (report 128 §5).
//
// The last part of a name is the twin: `live` must be refused, `dead` is safe. See README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind8g.mjs <outdir> [filter]'); process.exit(2); }
const FIELDS = Number(process.env.BLIND8G_FIELDS ?? 200);
const ROUNDS = Number(process.env.BLIND8G_ROUNDS ?? 30);
const list = [];
fs.mkdirSync(out, { recursive: true });

function emit(name, files, extra = {}) {
  if (filter && !name.includes(filter)) return;
  const d = path.join(out, name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, src] of Object.entries(files)) fs.writeFileSync(path.join(d, f), src);
  if (extra.platform) fs.writeFileSync(path.join(d, 'PLATFORM'), `platforms/${extra.platform}\n`);
  if (extra.steps) fs.writeFileSync(path.join(d, 'steps'), extra.steps);
  list.push(path.resolve(d));
}

const NODE = `import Io
import List
import Node exposing (Program)
import String
import Ref exposing (Ref)
import Dict exposing (Dict)
import Queue
import Task
import Schema


say : String → ⊤
say line = Debug.log line ⊤


show : List Int → String
show l = String.join (List.map l String.fromInt) ","


shows : List (List Int) → String
shows ls = String.join (List.map ls show) ";"


res : Result e String → String
res r =
    case r of
        Ok s → s
        Err _ → "err"
`;
const node = (body) => `${NODE}\n\n${body.trim()}\n`;
const ioMain = (lines) => `main : Program\nmain =\n    Io.run λ⊤ →\n${lines.trim().split('\n').map((l) => `        ${l}`).join('\n')}\n        Node.done`;

// ---- schema: program code that a `schema` declaration names ----------------------------------

const WRITES = {
  push: (l) => `List.push ${l} 99`,
  set: (l) => `List.set ${l} 0 99`,
  update: (l) => `List.update ${l} 0 λx → x + 99`,
  insert: (l) => `List.insertAt ${l} 0 99`,
  pop: (l) => `List.pop ${l}`,
};
const FORMS = ['named', 'module', 'partial', 'two', 'lambda', 'value'];
for (const form of FORMS) for (const [wk, W] of Object.entries(WRITES)) for (const twin of ['live', 'dead']) {
  const files = {};
  let decl, via;
  if (form === 'named' || form === 'two') {
    decl = `back : List Int → Result (List Schema.Issue) (List Int)\nback l = Ok (${W('l')})\n\n\n`;
    if (form === 'two') decl += `fwd : List Int → Result (List Schema.Issue) (List Int)\nfwd l = Ok l\n\n\n`;
    via = form === 'two' ? '(Schema.conversion fwd back)' : '(Schema.conversion Ok back)';
  } else if (form === 'module') {
    files['Util.beni'] = `import List\nimport Schema\n\n\npub back : List Int → Result (List Schema.Issue) (List Int)\nback l = Ok (${W('l')})\n`;
    decl = '';
    via = '(Schema.conversion Ok Util.back)';
  } else if (form === 'partial') {
    decl = `back : Int, List Int → Result (List Schema.Issue) (List Int)\nback k l = Ok (${W('l')})\n\n\n`;
    via = '(Schema.conversion Ok (back 1 _))';
  } else if (form === 'lambda') {
    decl = '';
    via = `(Schema.conversion Ok λl → Ok (${W('l')}))`;
  } else {
    decl = `conv : Schema.Conversion (List Int) (List Int)\nconv = Schema.conversion Ok λl → Ok (${W('l')})\n\n\n`;
    via = 'conv';
  }
  const read = twin === 'live' ? 'say ("v " ++ show v.items)' : 'say "v"';
  files['Main.beni'] = node(`${decl}pub schema Box =\n    items : List Int via ${via}\n    note : String\n\n\n${ioMain(`v = { items = [ 1, 2 ], note = "n" }\nsay (res (Box.print v))\n${read}`)}`)
    .replace('import Schema\n', form === 'module' ? 'import Schema\nimport Util\n' : 'import Schema\n');
  emit(`schema.print.${form}.${wk}.${twin}`, files);
}
// Parse: the worker hands the conversion the array it parsed, which nothing else holds.
emit('schema.parse.named.push.dead', { 'Main.beni': node(`fwd : List Int → Result (List Schema.Issue) (List Int)\nfwd l = Ok (List.push l 99)\n\n\npub schema Box =\n    items : List Int via (Schema.conversion fwd Ok)\n\n\n${ioMain(`case Box.parse "{\\"items\\":[1,2]}" of\n    Ok b → say ("b " ++ show b.items)\n    Err _ → say "err"`)}`) });
// A list of declarations that convert: each element's list is written by the print worker.
for (const twin of ['live', 'dead']) {
  emit(`schema.print.elements.push.${twin}`, { 'Main.beni': node(`back : List Int → Result (List Schema.Issue) (List Int)\nback l = Ok (List.push l 99)\n\n\npub schema Row =\n    List Int via (Schema.conversion Ok back)\n\n\npub schema Table =\n    rows : List Row\n\n\n${ioMain(`t = { rows = [ [ 1 ], [ 2 ] ] }\nsay (res (Table.print t))\n${twin === 'live' ? 'say ("t " ++ shows t.rows)' : 'say "t"'}`)}`) });
}
// The Elm Architecture: `update` prints the model to save it.
for (const twin of ['live', 'dead']) {
  const W = twin === 'live' ? 'List.push l 0' : 'List.push (List.copy l) 0';
  emit(`schema.tea.save.${twin}`, {
    'Main.beni': `import Html exposing (Html)
import Schema
import Tea


back : List Int → Result (List Schema.Issue) (List Int)
back l = Ok (${W})


pub schema Saved =
    items : List Int via (Schema.conversion Ok back)


type alias Model =
    items : List Int
    saved : String


type Msg
    = Bump
    | Save


update : Msg, Model → Model
update msg model =
    case msg of
        Bump →
            { model | items = List.map model.items λi → i + 1 }

        Save →
            case Saved.print { items = model.items } of
                Ok s → { model | saved = s }
                Err _ → model


view : Model → Html Msg
view model =
    <main>
        <button id="bump" onClick={Bump}>bump</button>
        <button id="save" onClick={Save}>save</button>
        <p id="items">{String.join (List.map model.items String.fromInt) " "}</p>
        <p id="saved">{model.saved}</p>
    </main>


main : Tea.Program
main =
    Tea.sandbox { init = λ⊤ → { items = [ 1 ], saved = "" }, update = update, view = view }
`,
  }, { platform: 'browser-tea', steps: 'click #bump\nclick #save\nclick #save\nclick #bump\n' });
}

// ---- page: in-place model writes seen through many forms of a view -----------------------------

const PAGE_VIEWS = {
  for: '<ul><For each={model.rows} keyed={False}>{λr → <li>{nums r}</li>}</For></ul>',
  forhelper: '<ul><For each={model.rows} keyed={False}>{rowView}</For></ul>',
  foridx: '<ul><For each={model.rows} keyed={False}>{λr i → <li>{i}: {nums r}</li>}</For></ul>',
  nested: '<ul><For each={model.rows} keyed={False}>{λr → <li><For each={r} keyed={False}>{λx → <b>{x}</b>}</For></li>}</For></ul>',
  tags: '<p class={List.map model.tags λt → ( t, True )}>{String.join model.tags ","}</p>',
  helper: '{firstRow model.rows}',
  letarm: `{if model.n ≥ 0 then
            r = Maybe.withDefault (List.head model.rows) []
            <p>{nums r}</p>
         else
            <p>no</p>
        }`,
};
const ENTRIES = {
  'browser-tea': ['import Tea', 'Tea.Program', 'Tea.sandbox'],
  browser: ['import Browser', 'Browser.Program', 'Browser.program'],
};
for (const [plat, [imp, ty, fn]] of Object.entries(ENTRIES)) for (const [vk, hole] of Object.entries(PAGE_VIEWS)) {
  emit(`page.${plat}.${vk}.dead`, {
    'Main.beni': `import Html exposing (Html)
${imp}


type alias Model =
    rows : List (List Int)
    tags : List String
    n : Int


type Msg
    = Grow
    | Tag


initModel : ⊤ → Model
initModel ⊤ = { rows = [ [ 1 ], [ 2 ] ], tags = [ "a" ], n = 0 }


nums : List Int → String
nums ns = String.join (List.map ns String.fromInt) " "


update : Msg, Model → Model
update msg model =
    case msg of
        Grow →
            k = model.n + 10
            { model | rows = List.update model.rows 0 λr → List.push r k, n = k - 9 }

        Tag →
            { model | tags = List.push model.tags "t", n = model.n + 1 }


rowView : List Int → Html Msg
rowView r = <li>{nums r}</li>


firstRow : List (List Int) → Html Msg
firstRow rows =
    case rows of
        [ r, …_ ] → <p>{nums r}</p>
        [] → <p>none</p>


view : Model → Html Msg
view model =
    <main>
        <button id="grow" onClick={Grow}>grow</button>
        <button id="tag" onClick={Tag}>tag</button>
        ${hole}
    </main>


main : ${ty}
main =
    ${fn} { init = initModel, update = update, view = view }
`,
  }, { platform: plat, steps: 'click #grow\nclick #tag\nclick #grow\nclick #tag\n' });
}
const INLINE_VIEWS = {
  text: '<p>{String.join model.tags ","}</p>\n        <p>{List.length model.tags}</p>\n        <p>{nums (List.concat model.rows)}</p>\n        <p>{nums model.inner.xs}</p>',
  len: '<p>{List.length model.tags}</p>\n        <p>{List.length model.inner.xs}</p>\n        <p>{model.n}</p>',
  head: '<p>{Maybe.withDefault (List.head model.tags) "-"}</p>\n        <p>{Maybe.withDefault (List.head (List.reverse model.inner.xs)) 0}</p>',
  innerrec: '<p>{nums model.inner.xs} {model.inner.k}</p>',
};
for (const [vk, holes] of Object.entries(INLINE_VIEWS)) {
  emit(`page.browser-inline.${vk}.dead`, {
    'Main.beni': `import Html exposing (Html)
import Tea


type alias Model =
    rows : List (List Int)
    tags : List String
    inner : { xs : List Int, k : Int }
    n : Int


type Msg
    = Grow
    | Tag
    | Inner
    | Swap


initModel : ⊤ → Model
initModel ⊤ = { rows = [ [ 1 ], [ 2 ] ], tags = [ "a" ], inner = { xs = [ 5 ], k = 0 }, n = 0 }


nums : List Int → String
nums ns = String.join (List.map ns String.fromInt) " "


update : Msg, Model → Model
update msg model =
    case msg of
        Grow →
            k = model.n + 10
            { model | rows = List.update model.rows 0 λr → List.push r k, n = k - 9 }

        Tag →
            { model | tags = List.push model.tags "t" }

        Inner →
            i = model.inner
            { model | inner = { i | xs = List.push i.xs 6 } }

        Swap →
            { model | tags = List.set model.tags 0 "z" }


view : Model → Html Msg
view model =
    <main>
        <button id="grow" onClick={Grow}>grow</button>
        <button id="tag" onClick={Tag}>tag</button>
        <button id="inner" onClick={Inner}>inner</button>
        <button id="swap" onClick={Swap}>swap</button>
        ${holes}
    </main>


main : Tea.Program
main =
    Tea.sandbox { init = initModel, update = update, view = view }
`,
  }, { platform: 'browser-inline', steps: 'click #tag\nclick #grow\nclick #inner\nclick #swap\nclick #tag\nclick #inner\n' });
}

// ---- cell: holders that a fiber, a cell or a finaliser keeps -----------------------------------

const CELLS = {
  'bracket.live': `r =\n    Task.bracket (λ⊤ → [ 1, 2 ]) (λrc _ → say ("rel " ++ show rc)) λrc →\n        List.push rc 3\nsay ("got " ++ show r)`,
  'bracket.dead': `r =\n    Task.bracket (λ⊤ → [ 1, 2 ]) (λrc _ → say "rel") λrc →\n        List.push rc 3\nsay ("got " ++ show r)`,
  'onexit.live': `xs = [ 1, 2 ]\nr =\n    Task.onExit (λ⊤ → List.length xs) λ_ → say ("fin " ++ show xs)\nys = List.push xs r\nsay ("got " ++ show ys)`,
  'defer.live': `Task.scope λs →\n    xs = [ 1, 2 ]\n    Task.defer s λ_ → say ("fin " ++ show xs)\n    ys = List.push xs 3\n    say ("got " ++ show ys)`,
  'spawn.live': `xs = [ 1, 2 ]\nfib = Task.spawn λ⊤ →\n    Io.sleep 5\n    say ("fib " ++ show xs)\nys = List.push xs 3\nsay ("got " ++ show ys)\nTask.join fib`,
  'refclosure.live': `xs = [ 1, 2 ]\nr = Ref.make λ⊤ → show xs\nys = List.push xs 3\nf = Ref.get r\nsay (f ⊤)\nsay ("got " ++ show ys)`,
  'refupdate.live': `r = Ref.make [ 1 ]\nold = Ref.get r\nRef.update r λl → List.push l 2\nsay ("old " ++ show old ++ " new " ++ show (Ref.get r))`,
  'refupdate.dead': `r = Ref.make [ 1 ]\nRef.update r λl → List.push l 2\nsay ("new " ++ show (Ref.get r))`,
  'refmodify.live': `r = Ref.make [ 1 ]\ngot = Ref.modify r λl → ( l, List.push l 2 )\nsay ("got " ++ show got ++ " new " ++ show (Ref.get r))`,
  'queue.live': `q = Queue.unbounded ⊤\nxs = [ 1 ]\n_ = Queue.offer q xs\nys = List.push xs 2\ngot = Queue.take q\nsay ("ys " ++ show ys ++ " got " ++ show (Maybe.withDefault got []))`,
  'queue.dead': `q = Queue.unbounded ⊤\n_ = Queue.offer q [ 1 ]\ngot = Maybe.withDefault (Queue.take q) []\nys = List.push got 2\nsay ("ys " ++ show ys)`,
  'dictget.live': `d = Dict.fromList [ ( 1, [ 1 ] ) ]\nl = Maybe.withDefault (Dict.get d 1) []\nm = List.push l 2\nsay ("d " ++ show (Maybe.withDefault (Dict.get d 1) []))\nsay ("m " ++ show m)`,
};
for (const [k, body] of Object.entries(CELLS)) emit(`cell.${k}`, { 'Main.beni': node(ioMain(body)) });

// ---- type: recursive, non-regular and row types ------------------------------------------------

emit('type.nest.live', { 'Main.beni': node(`type Nest a
    = Flat a
    | Deep (Nest (List a))


depth : Nest a → Int
depth n =
    case n of
        Flat _ → 0
        Deep m → 1 + depth m


firstList : Nest (List Int) → List Int
firstList n =
    case n of
        Flat l → l
        Deep _ → []


${ioMain('xs = [ 1, 2 ]\nn = Flat xs\nys = List.push (firstList n) 3\nsay ("xs " ++ show xs ++ " d " ++ String.fromInt (depth n))\nsay ("ys " ++ show ys)')}`) });
emit('type.nestdeep.live', { 'Main.beni': node(`type Nest a
    = Flat a
    | Deep (Nest (List a))


inner : Nest (List Int) → List Int
inner n =
    case n of
        Flat l → l
        Deep m →
            case m of
                Flat ls → List.concat ls
                Deep _ → []


bumpDeep : Nest (List Int) → Nest (List Int)
bumpDeep n =
    case n of
        Deep (Flat ls) → Deep (Flat (List.update ls 0 λl → List.push l 9))
        _ → n


${ioMain('xs = [ 1, 2 ]\nn = Deep (Flat [ xs, xs ])\nm = bumpDeep n\nsay ("n " ++ show (inner n))\nsay ("m " ++ show (inner m))')}`) });
const ROWREC = `type Node
    = Node { kids : List Node, items : List Int }


bump : { r | items : List Int } → { r | items : List Int }
bump r = { r | items = List.push r.items 9 }


kidItems : Node → List Int
kidItems (Node n) =
    case n.kids of
        [ Node k, …_ ] → k.items
        [] → []


bumpKid : Node → Node
bumpKid (Node n) =
    case n.kids of
        [ Node k, …rest ] → Node { n | kids = [ Node (bump k), …rest ] }
        [] → Node n
`;
emit('type.rowrec.live', { 'Main.beni': node(`${ROWREC}\n\n${ioMain('leaf = Node { kids = [], items = [ 1 ] }\nt = Node { kids = [ leaf ], items = [ 0 ] }\nt2 = bumpKid t\nsay ("t " ++ show (kidItems t))\nsay ("t2 " ++ show (kidItems t2))')}`) });
emit('type.rowrec2.live', { 'Main.beni': node(`${ROWREC}\n\n${ioMain('leaf = { kids = [], items = [ 1 ] }\nt = Node { kids = [ Node leaf ], items = [ 0 ] }\nb = bump leaf\nsay ("t " ++ show (kidItems t))\nsay ("b " ++ show b.items)')}`) });
emit('type.rose.live', { 'Main.beni': node(`type Rose a
    = Rose a (List (Rose a))


label : Rose a → a
label (Rose a _) = a


kids : Rose a → List (Rose a)
kids (Rose _ k) = k


mapLabel : Rose a, (a → a) → Rose a
mapLabel (Rose a k) f = Rose (f a) k


${ioMain('leaf = Rose [ 1 ] []\nt = Rose [ 0 ] [ leaf, leaf ]\nt2 = List.map (kids t) λr → mapLabel r λl → List.push l 5\nsay ("t " ++ String.join (List.map (kids t) λr → show (label r)) ";")\nsay ("t2 " ++ String.join (List.map t2 λr → show (label r)) ";")')}`) });

// ---- maker: one list at many places of a list ---------------------------------------------------

const MAKERS = ['List.initialize 3 λ_ → xs', 'List.repeat xs 3', 'List.map [ 1, 2, 3 ] λ_ → xs',
  'List.foldl [ 1, 2, 3 ] [] λ_ acc → List.push acc xs', 'List.concatMap [ 1, 2 ] λ_ → [ xs ]',
  'List.filterMap [ 1, 2 ] λ_ → Just xs', 'Dict.values (Dict.fromList [ ( 1, xs ), ( 2, xs ) ])',
  'List.indexedMap [ 1, 2 ] λ_ _ → xs', 'List.concat [ [ xs ], [ xs ] ]', '(List.unzip [ ( xs, 1 ), ( xs, 2 ) ]).0',
  'List.sortWith [ xs, xs ] λ_ _ → EQ', 'List.reverse [ xs, xs ]', 'List.intersperse [ xs ] xs',
  'List.filter [ xs, xs ] λ_ → True', '(List.partition [ xs, xs ] λ_ → True).0', 'List.take [ xs, xs ] 2',
  'List.drop [ xs, xs, xs ] 1', 'List.append [ xs ] [ xs ]'];
MAKERS.forEach((mk, i) => emit(`maker.m${String(i + 1).padStart(2, '0')}.live`, {
  'Main.beni': node(ioMain(`xs = [ 1 ]\nrs = ${mk}\nrs2 = List.update rs 0 λl → List.push l 9\nsay (shows rs2)`)),
}));
emit('maker.literal.dead', { 'Main.beni': node(ioMain('rs = [ [ 1 ], [ 2 ] ]\nrs2 = List.update rs 0 λl → List.push l 9\nsay (shows rs2)')) });

// ---- slow: checks whose work is not bounded by the walk's step limit -----------------------------

{
  const f = (i) => `f${String(i).padStart(4, '0')}`;
  let src = 'import Html exposing (Html)\nimport Tea\n\n\ntype alias Model =\n';
  for (let i = 1; i <= FIELDS; i++) src += `    ${f(i)} : List Int\n`;
  src += '\n\ntype Msg\n    = Tick\n\n\nspare : List Int\nspare = [ 0 ]\n\n\n';
  src += 'update : Msg, Model → Model\nupdate msg model =\n    case msg of\n        Tick →\n            { model\n';
  for (let i = 1; i <= FIELDS; i++) src += `                ${i === 1 ? '|' : ','} ${f(i)} = ${i < FIELDS ? `model.${f(i + 1)}` : 'spare'}\n`;
  src += '            }\n\n\n';
  src += `view : Model → Html Msg\nview model =\n    <main><button id="tick" onClick={Tick}>tick {List.length model.${f(1)}}</button></main>\n\n\n`;
  src += 'init : ⊤ → Model\ninit ⊤ =\n    {';
  for (let i = 1; i <= FIELDS; i++) src += `${i === 1 ? ' ' : '    , '}${f(i)} = [ ${i} ]\n`;
  src += '    }\n\n\nmain : Tea.Program\nmain =\n    Tea.sandbox { init = init, update = update, view = view }\n';
  emit(`slow.entry-shift.f${FIELDS}.dead`, { 'Main.beni': src }, { platform: 'browser-tea', steps: 'click #tick\n' });
}
{
  const a = (i) => `a${String(i).padStart(3, '0')}`;
  const depth = 10, heavy = 100;
  let src = 'import Io\nimport List\nimport Node exposing (Program)\n\n\ntype alias T0 =\n    List Int\n\n\n';
  for (let i = 1; i <= depth; i++) src += `type alias T${i} =\n    T${i - 1} × T${i - 1}\n\n\n`;
  src += 'mk1 : ⊤ → T1\nmk1 ⊤ = ( [ 1 ], [ 2 ] )\n\n\n';
  for (let i = 2; i <= depth; i++) src += `mk${i} : ⊤ → T${i}\nmk${i} ⊤ = ( mk${i - 1} ⊤, mk${i - 1} ⊤ )\n\n\n`;
  const T = `T${depth}`;
  src += `step : ${T}, Int → ${T}\nstep t n =\n    if n > 0 then\n        t\n    else\n        t\n\n\ntype alias R =\n`;
  for (let i = 1; i <= ROUNDS; i++) src += `    ${a(i)} : List Int\n`;
  src += `\n\nrot : R, ${T}, Int → R\nrot r t0 n =\n`;
  for (let i = 1; i <= heavy; i++) src += `    t${i} = step t${i - 1} ${i}\n`;
  src += `    if n ≤ 0 then\n        { r | ${a(1)} = List.push r.${a(1)} 1 }\n    else\n        rot\n            {`;
  for (let i = 1; i <= ROUNDS; i++) src += `${i === 1 ? ' ' : '            , '}${a(i)} = r.${a(i === ROUNDS ? 1 : i + 1)}\n`;
  src += `            }\n            t${heavy}\n            (n - 1)\n\n\nmkR : ⊤ → R\nmkR ⊤ =\n    {`;
  for (let i = 1; i <= ROUNDS; i++) src += `${i === 1 ? ' ' : '    , '}${a(i)} = [ ${i} ]\n`;
  src += `    }\n\n\nmain : Program\nmain =\n    Io.run λ⊤ →\n        r = rot (mkR ⊤) (mk${depth} ⊤) 3\n        Debug.log (String.fromInt (List.length r.${a(1)})) ⊤\n        Node.done\n`;
  emit(`slow.group-rounds.r${ROUNDS}.dead`, { 'Main.beni': src });
}

fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
