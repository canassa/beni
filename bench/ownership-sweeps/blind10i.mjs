// blind10i.mjs <outdir> [filter]: research report 133, a tenth blind test (reader I), at the boundary:
// markup, platforms and codecs. Seven families:
//
// - `dom.*`: The Elm Architecture on `browser` (the `dom` lowering): `update` writes a list of the model in
//   place (`List.push`, `List.set`, `List.update`; for rows, a `List.update` of a list of lists), and the
//   view shows it through one of 26 holders: a text hole, its length, a same-module helper, a helper of a
//   second module (of the list, of the whole model), a helper handed a record built in the render or a
//   sub-record, `For` by position, by reference, with the position, with a top-level row function or a
//   partial application, a `For` of rows of rows, rows shown by a helper, a keyed `Show`, class lists
//   (built and kept in the model), a style list, a `let` of the view, `Html.map`, a component with a prop
//   or with children, a controlled input, a nested helper, a branch, a `case` on the list. `live` keeps
//   the old list in `model.saved` and shows it. Names: `dom.<holder>.<write>.<twin>`.
// - `inline.*`: the same pages on `browser-inline` (see below for its oracle).
// - `tea.*`: `Tea.element` on `browser-tea`: a command (`Cmd.perform`, a lambda, `Cmd.keyed` under each
//   policy, a list as the key, `Cmd.task`, `Cmd.afterRender`, `Cmd.batch`, `Cmd.map`, `Cmd.do`) or a
//   subscription (`Sub.listen` body or key, `Time.every`, `Browser.Events.onResize`, `Sub.map`,
//   `Sub.batch`) holds a list of the model (`live`) or a new list (`dead`); then `update` writes the model's
//   list in place, and the holder reads it after a sleep. Names: `tea.<cmd|sub>.<holder>.<twin>`.
// - `memo.*`: a `let` of a view, a helper's root or a component's root, written in place in the view. The
//   `dom` lowering keeps such a `let` across renders while the paths it reads do not change. On
//   `browser` and `browser-tea`. Names: `memo.<platform>.<shape>.<twin>`; `kept` reads the list again in
//   the same render.
// - `ssr.*`: markup on `node` (`Ssr.render`) over a list, rendered after (`live`) or before (`dead`) the
//   list is written: 14 holders, among them a closure, a pair, a list of markup and a second render.
// - `codec.*`: `Json.encodeValue`/`decodeValue` with derived codecs, `Schema.decode`, `encode`,
//   `write`/`read`, a declared schema's `Box.schema`, `Schema.converted`: a decoded or encoded list,
//   which may share its array with the list it came from, is written, and the other read (`live`) or not.
// - `slow.*`: a chain of writes, each of the list the one before answered, and the control with lists
//   apart (`BLIND10I_CHAINS`), for the time of v3's own walk.
//
// The last part of a name is the twin kind: `live` reads the old list after the write (must be refused or
// print the same), `kept` the same through a holder, `dead` reads nothing after it (safe; a refusal is a
// precision loss). See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind10i.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const progs = [];
// `browser-inline` edits lists in place in its plain build (its manifest says `"lists": "in-place"`), so the
// plain build is no oracle there. Its programs are built for a copy of the platform whose manifest has no
// `"lists"` key: the plain build copies, and `--ownership-everywhere` edits in place. The copy is written
// below the output directory; `PLATFORM` names it relative to the repository root, as run.mjs reads it.
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const INLINE = path.relative(root, path.resolve(out, "_platforms/browser-inline"));
{
  fs.mkdirSync(path.resolve(out, "_platforms"), { recursive: true });
  for (const d of ["browser-inline", "html"]) fs.cpSync(path.join(root, "platforms", d), path.resolve(out, "_platforms", d), { recursive: true });
  const mf = path.resolve(out, "_platforms/browser-inline/beni.json");
  fs.writeFileSync(mf, fs.readFileSync(mf, "utf8").replace(/\n *"lists": "in-place",/, ""));
}
const add = (name, files, platform, steps) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files, platform, steps });
};

// ---- dom: a list of the model, written in place, seen through a holder of the view -----------------------

// What `update`'s `Add` arm does to `model.items` (a `List Int`) or `model.rows` (a `List (List Int)`).
// `live` keeps the old list in `model.saved` and shows it: the write must be refused, or show the same.
const WRITES = {
  push: (m) => `List.push ${m}.items 7`,
  set: (m) => `List.set ${m}.items 0 (List.length ${m}.items)`,
  update: (m) => `List.update ${m}.items 0 λx → x + 10`,
};

// Each holder: extra declarations, the view's body (in terms of `model`), and an optional second module.
const HELPERS = `showList : List Int → Html Msg
showList xs = <span class="list">{String.join (List.map xs String.fromInt) ","}</span>


showRec : { xs : List Int } → Html Msg
showRec r = <span class="rec">{String.join (List.map r.xs String.fromInt) ","}</span>


row : Int → Html Msg
row x = <li>{x}</li>


rowAt : String, Int → Html Msg
rowAt tag x = <li>{tag}{x}</li>


outer : List Int → Html Msg
outer xs = <div>{showList xs}{List.length xs}</div>
`;
const OTHER = `import Html exposing (Html)


pub showOther : List Int → Html msg
showOther xs = <em>{String.join (List.map xs String.fromInt) ","}</em>


pub countOf : { r | items : List Int } → Int
countOf m = List.length m.items
`;
const COMP = `import Html exposing (Html)


pub view : { xs : List Int } → Html msg
view props = <ol>{String.join (List.map props.xs String.fromInt) ";"}</ol>


pub boxed : { children : Html msg } → Html msg
boxed props = <section class="boxed">{props.children}</section>
`;

const HOLDERS = {
  text: `<p>{String.join (List.map model.items String.fromInt) ","}</p>`,
  length: `<p>{List.length model.items}</p>`,
  helper: `<p>{showList model.items}</p>`,
  other: `<p>{Other.showOther model.items}</p>`,
  othercount: `<p>{Other.countOf model}</p>`,
  rec: `<p>{showRec { xs = model.items }}</p>`,
  sub: `<p>{showRec model.sub}</p>`,
  forpos: `<ul><For each={model.items} keyed={False}>{λx → <li>{x}</li>}</For></ul>`,
  forref: `<ul><For each={model.items}>{λx → <li>{x}</li>}</For></ul>`,
  forindex: `<ul><For each={model.items} keyed={False}>{λx i → <li>{x}@{i}</li>}</For></ul>`,
  fortop: `<ul><For each={model.items} keyed={False}>{row}</For></ul>`,
  forpart: `<ul><For each={model.items} keyed={False}>{rowAt "r" _}</For></ul>`,
  rows: `<div><For each={model.rows} keyed={False}>{λr → <ul><For each={r} keyed={False}>{λx → <li>{x}</li>}</For></ul>}</For></div>`,
  rowshelper: `<div><For each={model.rows} keyed={False}>{λr → <p>{showList r}</p>}</For></div>`,
  show: `<div><Show when={List.head model.rows} keyed={λr → List.length r}>{λr → <p>{showList r}</p>}</Show></div>`,
  class: `<p id="c" class={List.map model.items λx → ( "c\${String.fromInt x}", True )}>c</p>`,
  classfield: `<p id="c" class={model.cls}>c</p>`,
  stylefield: `<p id="s" style={model.sty}>s</p>`,
  let: null, // built below
  map: `<div>{Html.map (showList model.items) λm → m}</div>`,
  comp: `<div><Comp xs={model.items} /></div>`,
  children: `<div><Comp.boxed>{showList model.items}</Comp.boxed></div>`,
  input: `<input id="i" value={String.join (List.map model.items String.fromInt) ","} />`,
  nested: `<p>{outer model.items}</p>`,
  branch: `<p>{if List.length model.items > 2 then showList model.items else <b>short</b>}</p>`,
  case: `<p>{case model.items of\n    [ a, …rest ] →\n        <b>{a}:{List.length rest}</b>\n\n    [] →\n        <b>none</b>\n}</p>`,
};

const MODEL = `type alias Model =
    items : List Int
    rows : List (List Int)
    sub : { xs : List Int }
    cls : List (String × Bool)
    sty : List (String × String)
    saved : List Int
`;
const INIT = `{ items = [ 1, 2 ], rows = [ [ 1, 2 ], [ 3 ] ], sub = { xs = [ 5, 6 ] }, cls = [ ( "a", True ), ( "b", True ) ], sty = [ ( "color", "red" ), ( "margin", "1px" ) ], saved = [] }`;

function writeFor(holder, write, twin) {
  const keep = twin === 'live' ? ', saved = model.items' : '';
  if (holder === 'rows' || holder === 'rowshelper' || holder === 'show') {
    const w = { push: 'List.push r 7', set: 'List.set r 0 (List.length r)', update: 'List.update r 0 λx → x + 10' }[write];
    const keepR = twin === 'live' ? ', saved = Maybe.withDefault (List.head model.rows) []' : '';
    return `{ model | rows = List.update model.rows 0 λr → ${w}${keepR} }`;
  }
  if (holder === 'sub') {
    const w = WRITES[write]('model.sub').replace('model.sub.items', 'model.sub.xs').replace('model.sub.items', 'model.sub.xs');
    const keepS = twin === 'live' ? ', saved = model.sub.xs' : '';
    return `{ model | sub = { xs = ${w.replaceAll('model.sub.items', 'model.sub.xs')} }${keepS} }`;
  }
  if (holder === 'classfield') {
    const w = { push: 'List.push model.cls ( "z", True )', set: 'List.set model.cls 0 ( "a", False )', update: 'List.update model.cls 1 λp → ( "b", False )' }[write];
    return `{ model | cls = ${w}${twin === 'live' ? ', saved = List.map model.cls λ( k, _ ) → String.length k' : ''} }`;
  }
  if (holder === 'stylefield') {
    const w = { push: 'List.push model.sty ( "padding", "2px" )', set: 'List.set model.sty 0 ( "color", "" )', update: 'List.update model.sty 1 λp → ( "margin", "" )' }[write];
    return `{ model | sty = ${w}${twin === 'live' ? ', saved = List.map model.sty λ( k, _ ) → String.length k' : ''} }`;
  }
  return `{ model | items = ${WRITES[write]('model')}${keep} }`;
}

function domSrc(holder, write, twin, platform) {
  let body = HOLDERS[holder];
  if (holder === 'let') body = null;
  const savedHole = `<p id="saved">{String.join (List.map model.saved String.fromInt) ","}</p>`;
  const buttons = `<button id="add" onClick={Add}>add</button>`;
  let viewBody;
  if (holder === 'let') {
    viewBody = `shown = model.items\n<main>\n    ${buttons}\n    <p>{showList shown}</p>\n    <p>{List.length shown}</p>\n    ${savedHole}\n</main>`;
  } else {
    viewBody = `<main>\n    ${buttons}\n${ind(body, 4)}\n    ${savedHole}\n</main>`;
  }
  const imports = platform === 'inline'
    ? `import Browser\nimport Html exposing (Html)\nimport List\nimport Other\nimport Comp\nimport Tea`
    : `import Browser\nimport Html exposing (Html)\nimport List\nimport Other\nimport Comp`;
  const main = platform === 'inline'
    ? `main : Tea.Program\nmain = Browser.mountAt (Tea.sandbox { init = λ⊤ → ${INIT}, update = update, view = view }) "root"`
    : `main : Browser.Program\nmain = Browser.program { init = λ⊤ → ${INIT}, update = update, view = view }`;
  return `${imports}


type Msg
    = Add


${MODEL}

update : Msg, Model → Model
update msg model =
    case msg of
        Add →
            ${writeFor(holder, write, twin)}


${HELPERS}

view : Model → Html Msg
view model =
${ind(viewBody, 4)}


${main}
`;
}

for (const holder of Object.keys(HOLDERS)) for (const write of Object.keys(WRITES)) for (const twin of ['live', 'dead']) {
  add(`dom.${holder}.${write}.${twin}`, { 'Main.beni': domSrc(holder, write, twin, 'dom'), 'Other.beni': OTHER, 'Comp.beni': COMP },
    'platforms/browser', 'click #add\nclick #add\nclick #add\n');
  add(`inline.${holder}.${write}.${twin}`, { 'Main.beni': domSrc(holder, write, twin, 'inline'), 'Other.beni': OTHER, 'Comp.beni': COMP },
    INLINE, 'element "root"\nclick #add\nclick #add\nclick #add\n');
}

// ---- tea: a command, a subscription or a message holds a list of the model -----------------------------------

// `Keep` makes the holder; `Add` then pushes `model.items` in place; the holder reads it later. `live` hands
// the holder the list; `dead` a new list of its length.
const TEA_CMDS = {
  perform: (xs) => `Cmd.perform (job ${xs} _)`,
  lambda: (xs) => `Cmd.perform λsend → job ${xs} send`,
  restart: (xs) => `Cmd.keyed "k" Cmd.Restart (job ${xs} _)`,
  queue: (xs) => `Cmd.keyed "k" Cmd.Queue (job ${xs} _)`,
  ignore: (xs) => `Cmd.keyed "k" Cmd.Ignore (job ${xs} _)`,
  concurrent: (xs) => `Cmd.keyed "k" Cmd.Concurrent (job ${xs} _)`,
  keyedkey: (xs) => `Cmd.keyed ${xs} Cmd.Restart (job [] _)`,
  task: (xs) => `Cmd.task (λ⊤ → later ${xs}) Show`,
  after: (xs) => `Cmd.afterRender (now ${xs} _)`,
  batch: (xs) => `Cmd.batch [ Cmd.none, Cmd.perform (job ${xs} _) ]`,
  map: (xs) => `Cmd.map (Cmd.perform (job ${xs} _)) "m" λm → m`,
  doit: (xs) => `Cmd.do λ⊤ → logIt ${xs}`,
};
const TEA_SUBS = {
  listen: (xs) => `Sub.listen "k" (subBody ${xs} _) Show`,
  listenkey: (xs) => `Sub.listen ${xs} (subBody [] _) Show`,
  every: (xs) => `Time.every (Time.millis 100) λ_ → Show (render ${xs})`,
  resize: (xs) => `Browser.Events.onResize λ_ → Show (render ${xs})`,
  map: (xs) => `Sub.map (Time.every (Time.millis 100) λ_ → render ${xs}) Show`,
  batch: (xs) => `Sub.batch [ Sub.none, Time.every (Time.millis 100) λ_ → Show (render ${xs}) ]`,
};

function teaSrc(kind, holder, twin) {
  const bind = `xs = ${twin === 'live' ? 'model.items' : '[ List.length model.items ]'}`;
  const keep = kind === 'cmd' ? `${bind}\n            ( model, ${TEA_CMDS[holder]('xs')} )` : '( { model | on = True }, Cmd.none )';
  const subs = kind === 'sub' ? `${bind}\nif model.on then\n    ${TEA_SUBS[holder]('xs')}\nelse\n    Sub.none` : 'Sub.none';
  return `import Browser.Events
import Cmd exposing (Cmd)
import Html exposing (Html)
import List
import Sub exposing (Sub)
import Tea
import Time


type Msg
    = Add
    | Keep
    | Show String


type alias Model =
    items : List Int
    log : List String
    on : Bool


render : List Int → String
render xs = String.join (List.map xs String.fromInt) ","


job : List Int, Cmd.Send Msg → ⊤
job xs send =
    Time.sleep (Time.millis 100)
    send (Show (render xs))


now : List Int, Cmd.Send Msg → ⊤
now xs send = send (Show (render xs))


logIt : List Int → ⊤
logIt xs =
    Time.sleep (Time.millis 100)
    Debug.log (render xs) ⊤


later : List Int → String
later xs =
    Time.sleep (Time.millis 100)
    render xs


subBody : List Int, Cmd.Send String → ⊤
subBody xs send =
    Time.sleep (Time.millis 100)
    send (render xs)


update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Add →
            ( { model | items = List.push model.items 7 }, Cmd.none )

        Keep →
            ${keep}

        Show s →
            ( { model | log = List.push model.log s }, Cmd.none )


subscriptions : Model → Sub Msg
subscriptions model =
${ind(subs, 4)}


view : Model → Html Msg
view model =
    <main>
        <button id="keep" onClick={Keep}>keep</button>
        <button id="add" onClick={Add}>add</button>
        <p id="items">{render model.items}</p>
        <ol><For each={model.log} keyed={False}>{λl → <li>{l}</li>}</For></ol>
    </main>


main : Tea.Program
main =
    Tea.element
        { init = λ⊤ → ( { items = [ 1, 2 ], log = [], on = False }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
`;
}
const TEA_STEPS = 'click #keep\nclick #add\nadvance 50\nclick #add\nadvance 150\nclick #add\nevent window resize\nadvance 150\n';
for (const holder of Object.keys(TEA_CMDS)) for (const twin of ['live', 'dead']) {
  add(`tea.cmd.${holder}.${twin}`, { 'Main.beni': teaSrc('cmd', holder, twin) }, 'platforms/browser-tea', TEA_STEPS);
}
for (const holder of Object.keys(TEA_SUBS)) for (const twin of ['live', 'dead']) {
  add(`tea.sub.${holder}.${twin}`, { 'Main.beni': teaSrc('sub', holder, twin) }, 'platforms/browser-tea', TEA_STEPS);
}

// ---- memo: a `let` of a view, which the `dom` lowering keeps across renders, written in place ----------------

// backend.md §15.4 *The `let` rule*: a `let` read only by markup is evaluated at the root's first render and
// again only when a path it reads changed; otherwise the root keeps its last value (`d<k>`). The checker walks
// `view` as a function whose `let`s are made on each call. Each makes the kept list from no path, or from
// scalar paths only, and writes it in place in the view: `live`, since the next render reads it (must be
// refused); `kept` also reads it after the write in the same render (must be refused); `dead` makes it from a list path of the model, which the root treats as changed on every render.
const MEMO = {
  const: { make: 'xs = [ 1, 2 ]', write: 'ys = List.push xs model.k' },
  set: { make: 'xs = [ 1, 2 ]', write: 'ys = List.set xs 0 model.k' },
  update: { make: 'xs = [ 1, 2 ]', write: 'ys = List.update xs 0 λx → x + model.k' },
  scalar: { make: 'xs = List.repeat 2 model.j', write: 'ys = List.push xs model.k' },
  record: { make: 'r = { l = [ 7 ], n = 1 }', write: 'ys = List.push r.l model.k', fresh: 'r = { l = List.copy model.items, n = 1 }', read: 'r.l' },
  tuple: { make: 'p = ( [ 7 ], 1 )', write: 'ys =\n    case p of\n        ( l, _ ) →\n            List.push l model.k', fresh: 'p = ( List.copy model.items, 1 )', read: 'Tuple.first p' },
  hole: { make: 'xs = [ 1, 2 ]', write: null, hole: '{show (List.push xs model.k)}' },
  helper: { make: 'xs = [ 1, 2 ]', write: null, hole: '{pushShow xs model.k}' },
  nested: { make: 'xss = [ [ 1 ], [ 2 ] ]', write: 'ys = List.concat (List.update xss 0 λl → List.push l model.k)', fresh: 'xss = [ List.copy model.items ]', read: 'List.concat xss' },
  inhelper: { make: 'xs = [ 1, 2 ]', write: null, hole: '{card model.k}' },
  incomp: { make: 'xs = [ 1, 2 ]', write: null, hole: '<Comp.counter n={model.k} />' },
  chain: { make: 'xs = [ 1 ]', write: 'ys0 = List.push xs model.k\nys = List.push ys0 model.k' },
};
// The body of a helper's or a component's own root, with a let it writes: `live` makes it from nothing,
// `kept` also reads it after the write, `dead` makes the written list inside the written let's expression.
function memoRoot(twin, k, tag) {
  if (twin === 'dead') return `ys = List.push (fresh ${k}) ${k}\n<${tag}>{show ys}</${tag}>`;
  const old = twin === 'kept' ? '{show xs}' : '';
  return `xs = [ 1, 2 ]\nys = List.push xs ${k}\n<${tag}>{show ys}${old}</${tag}>`;
}
const memoComp = (twin) => `import Html exposing (Html)
import List


show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


fresh : Int → List Int
fresh k = [ 1, k ]


pub counter : { n : Int } → Html msg
counter props =
${ind(memoRoot(twin, 'props.n', 'i'), 4)}
`;
function memoSrc(shape, twin, platform) {
  const s = MEMO[shape];
  const make = twin === 'dead' ? (s.fresh ?? s.make.replace(/= .*/, '= List.copy model.items')) : s.make;
  const readOld = s.read ?? (shape === 'nested' ? 'List.concat xss' : 'xs');
  const lines = [make];
  if (s.write) lines.push(s.write);
  const holes = [s.write ? '<p id="ys">{show ys}</p>' : `<p id="ys">${s.hole}</p>`];
  if (twin === 'kept') holes.push(`<p id="old">{show (${readOld.replace('Tuple.first p', 'first p')})}</p>`);
  const body = `${lines.join('\n')}\n<main>\n    <button id="add" onClick={Add}>add</button>\n    <button id="bump" onClick={Bump}>bump</button>\n${ind(holes.join('\n'), 4)}\n</main>`;
  const tea = platform === 'tea';
  return `import Browser
import Comp
import Html exposing (Html)
import List
${tea ? 'import Cmd exposing (Cmd)\nimport Sub\nimport Tea\n' : ''}

type Msg
    = Add
    | Bump


type alias Model =
    k : Int
    j : Int
    items : List Int


update : Msg, Model → Model
update msg model =
    case msg of
        Add →
            { model | k = model.k + 1 }

        Bump →
            { model | j = model.j + 1 }


show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


first : List Int × Int → List Int
first p =
    case p of
        ( l, _ ) →
            l


pushShow : List Int, Int → String
pushShow xs k = show (List.push xs k)


fresh : Int → List Int
fresh k = [ 1, k ]


-- A helper and a component whose own root has a let that it writes.
card : Int → Html Msg
card k =
${ind(memoRoot(twin, 'k', 'b'), 4)}


view : Model → Html Msg
view model =
${ind(body, 4)}


${tea
    ? 'main : Tea.Program\nmain =\n    Tea.element\n        { init = λ⊤ → ( { k = 0, j = 1, items = [ 5 ] }, Cmd.none )\n        , update = λm md → ( update m md, Cmd.none )\n        , view = view\n        , subscriptions = λ_ → Sub.none\n        }'
    : 'main : Browser.Program\nmain = Browser.program { init = λ⊤ → { k = 0, j = 1, items = [ 5 ] }, update = update, view = view }'}
`;
}
for (const platform of ['dom', 'tea']) for (const shape of Object.keys(MEMO)) for (const twin of ['live', 'kept', 'dead']) {
  add(`memo.${platform}.${shape}.${twin}`, { 'Main.beni': memoSrc(shape, twin, platform), 'Comp.beni': memoComp(twin) },
    platform === 'tea' ? 'platforms/browser-tea' : 'platforms/browser', 'click #add\nclick #bump\nclick #add\n');
}

// ---- ssr: markup on `node`, rendered before or after a write of what it holds --------------------------------

const SSR_HDR = `import Html exposing (Html)
import List
import Node exposing (Program)
import Ssr
import Comp


show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


item : Int → Html msg
item x = <li>{x}</li>


page : List Int → Html msg
page xs = <p>{show xs}</p>
`;
// Each: the markup over \`xs\`. \`live\` renders it after the write; \`dead\` renders it before.
const SSR_HOLDERS = {
  text: '<p>{show xs}</p>',
  helper: '<div>{page xs}</div>',
  forpos: '<ul><For each={xs} keyed={False}>{λx → <li>{x}</li>}</For></ul>',
  fortop: '<ul><For each={xs} keyed={False}>{item}</For></ul>',
  forref: '<ul><For each={xs}>{item}</For></ul>',
  show: '<div><Show when={List.head [ xs ]} keyed={λl → List.length l}>{λl → <p>{show l}</p>}</Show></div>',
  class: '<p class={List.map xs λx → ( "c${String.fromInt x}", True )}>c</p>',
  map: '<div>{Html.map (page xs) λq → q}</div>',
  comp: '<div><Comp xs={xs} /></div>',
  children: '<div><Comp.boxed>{page xs}</Comp.boxed></div>',
  closure: null,
  pair: null,
  list: null,
  twice: null,
};
function ssrSrc(holder, twin) {
  let make; let use;
  if (holder === 'closure') { make = 'm = λ⊤ → page xs'; use = 'Ssr.render (m ⊤)'; }
  else if (holder === 'pair') { make = 'm = ( page xs, 1 )'; use = 'case m of\n            ( h, _ ) →\n                Ssr.render h'; }
  else if (holder === 'list') { make = 'm = [ page xs, page [ 0 ] ]'; use = 'String.join (List.map m Ssr.render) "|"'; }
  else if (holder === 'twice') { make = 'm = page xs\nfirst = Ssr.render m'; use = 'first ++ Ssr.render m'; }
  else { make = `m = ${SSR_HOLDERS[holder]}`; use = 'Ssr.render m'; }
  const body = twin === 'live'
    ? `xs = [ 1, 2 ]\n${make}\nys = List.push xs 3\nout = ${use}\nNode.print "\${out} \${show ys}"`
    : `xs = [ 1, 2 ]\n${make}\nout = ${use}\nys = List.push xs 3\nNode.print "\${out} \${show ys}"`;
  return `${SSR_HDR}\n\nmain : Program\nmain =\n${ind(body, 4)}\n`;
}
for (const holder of Object.keys(SSR_HOLDERS)) for (const twin of ['live', 'dead']) {
  add(`ssr.${holder}.${twin}`, { 'Main.beni': ssrSrc(holder, twin), 'Comp.beni': COMP }, null, null);
}

// ---- codec: a value decoded or encoded may share an array with the value it came from ---------------------------

const CODEC_HDR = `import List
import Json
import Node exposing (Program)
import Schema exposing (Schema)


show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


schema Box =
    items : List Int
    n : Int


ints : Schema (List Int) (List Int)
ints = Schema.list Schema.int
`;
// Each answers \`Result _ (List Int)\` from \`xs\` (a \`case\` binds \`ys\`); the frame writes \`ys\` and reads \`xs\` (\`live\`) or not.
const CODECS = {
  jsonvalue: `case Json.encodeValue xs of\n    Ok v →\n        back v\n\n    Err _ →\n        Err "enc"`,
  schemadecode: `plain (Schema.decode ints xs)`,
  schemaencode: `plain (Schema.encode ints xs)`,
  writeread: `case Schema.write ints xs of\n    Ok v →\n        plain (Schema.read ints v)\n\n    Err _ →\n        Err "write"`,
  boxdecode: `boxItems (Schema.decode (Box.schema ⊤) { items = xs, n = 1 })`,
  boxencode: `boxItems (Schema.encode (Box.schema ⊤) { items = xs, n = 1 })`,
  boxwrite: `case Schema.write (Box.schema ⊤) { items = xs, n = 1 } of\n    Ok v →\n        boxItems (Schema.read (Box.schema ⊤) v)\n\n    Err _ →\n        Err "write"`,
  jsonvalue2: `case Json.encodeValue (box xs) of\n    Ok v →\n        back2 v\n\n    Err _ →\n        Err "enc"`,
  erased: `plain (Schema.decode (Schema.converted ints (Schema.conversion (λl → Ok l) λl → Ok l)) xs)`,
};
function codecSrc(kind, twin) {
  const read = twin === 'live' ? '${show xs} ' : '';
  return `${CODEC_HDR}

plain : Result (List Schema.Issue) (List Int) → Result String (List Int)
plain r =
    case r of
        Ok l →
            Ok l

        Err _ →
            Err "issues"


boxItems : Result (List Schema.Issue) { items : List Int, n : Int } → Result String (List Int)
boxItems r =
    case r of
        Ok b →
            Ok b.items

        Err _ →
            Err "issues"


box : List Int → { items : List Int, n : Int }
box l = { items = l, n = 1 }


back2 : Schema.Value → Result String (List Int)
back2 v =
    r : Result (List Schema.Issue) { items : List Int, n : Int }
    r = Json.decodeValue v
    boxItems r


back : Schema.Value → Result String (List Int)
back v = plain (Json.decodeValue v)


main : Program
main =
    xs : List Int
    xs = [ 1, 2, 3 ]
    r =
${ind(CODECS[kind], 8)}
    case r of
        Ok ys →
            zs = List.push ys 4
            Node.print "${read}\${show zs}"

        Err why →
            Node.print why
`;
}
for (const kind of Object.keys(CODECS)) for (const twin of ['live', 'dead']) {
  add(`codec.${kind}.${twin}`, { 'Main.beni': codecSrc(kind, twin) }, null, null);
}

// ---- slow: a chain of in-place writes, each of the list the one before answered -------------------------------

// `x1 = List.push x0 k`, `x2 = List.push x1 k`, … in one function (`chain`), and the control with as many
// pushes on lists apart (`apart`). Time v3's own phase with `--self-profile` (its `ownership3_module`
// events). Set `BLIND10I_CHAINS` to a comma-separated list of lengths (default 50,100,200,400).
const CHAINS = (process.env.BLIND10I_CHAINS ?? '50,100,200,400').split(',').map(Number);
for (const n of CHAINS) for (const kind of ['chain', 'apart']) {
  const lines = ['x0 = [ k ]'];
  for (let i = 0; i < n; i++) lines.push(kind === 'chain' ? `x${i + 1} = List.push x${i} k` : `x${i + 1} = List.push [ k ] ${i}`);
  add(`slow.${kind}${n}.dead`, {
    'Main.beni': `import List\nimport Node exposing (Program)\n\n\nf : Int → List Int\nf k =\n${ind(lines.join('\n'), 4)}\n    x${n}\n\n\nmain : Program\nmain = Node.print (String.fromInt (List.length (f 1)))\n`,
  }, null, null);
}

// ---- write the programs ------------------------------------------------------------------------------------

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, s] of Object.entries(p.files)) fs.writeFileSync(path.join(d, f), s);
  if (p.platform) fs.writeFileSync(path.join(d, 'PLATFORM'), `${p.platform}\n`);
  if (p.steps) fs.writeFileSync(path.join(d, 'steps'), p.steps);
  list.push(d);
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${progs.length} programs in ${out}`);
