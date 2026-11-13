// blind6e.mjs <outdir> [filter]: research report 124, a sixth blind test (reader E), written as
// applications. Five families:
//
// - `row.*`: the entry rule (kernel §6.13) where a function of the program's record takes the model
//   as an extensible record (`{ r | n : Int }`) or a type variable, and keeps it: a `view` whose outer
//   handler shows the model when an inner click bubbles to it, a `Sub.listen` body that keeps
//   running across messages, a `Browser.hosted` `update` or `settle` that keeps it in `Task.soon` or in a fiber that sleeps,
//   a `Tea.document` view. The record's function is given directly, as a partial application or
//   through a lambda. Names: `row.<role>.<type>.<given>.<twin>`.
// - `app.*`: The Elm Architecture written the usual way (`browser`, `browser-tea`,
//   `browser-inline`): the model's lists are pushed, set or updated in place by `update`, and
//   a `For` row's message, a bubbling handler, a helper, text holes or a `Show` body holds them. Names:
//   `app.<platform>.<holder>.<write>.<twin>`.
// - `ssr.*`: markup rendered on `node` (`Ssr.render`), where a hole, a helper, a `For` row, a
//   `Show` body or a component's children hold a list that the frame writes after. Names:
//   `ssr.<holder>.<twin>`.
// - `fiber.*`: `Task`/`Io` fibers that really wait and read a list that another fiber writes.
//   Names: `fiber.<shape>.<twin>`.
// - `top.*`: a function that hands its own new list to its function parameter and then writes it,
//   reached through a `Ref` (the code that calls it is the default use, kernel §6.8) or as a
//   command's body whose `send` has the program's own alias. Names: `top.<route>[.<alias>].<twin>`.
//
// The last part of a name is the twin kind: `live` reads the old list after the write (must be
// refused or print the same), `dead` reads nothing after it (safe; a refusal is a precision loss).
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind6e.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');

const progs = [];
const add = (name, files, platform, steps) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files, platform, steps });
};

// ---- row: the entry and a generic function of the record ---------------------------------------

// The keeper's parameter type. `row` and `row2` are extensible records; `var` a type variable;
// `conc` the model itself (the control: it must be refused when it keeps).
const RTYPES = {
  row: '{ r | n : Int }',
  row2: '{ r | n : Int, tag : String }',
  var: 'a',
  conc: 'Model',
};
const MODEL = 'type alias Model =\n    items : List Int\n    n : Int\n    tag : String\n';
const INIT0 = '{ items = [ 1 ], n = 1, tag = "t" }';
const PUSH = '{ model | items = List.push model.items 7, n = model.n + 1 }';
// What the keeper shows: the whole model, or nothing of it.
const shown = (twin) => (twin === 'live' ? 'Debug.toString model' : '"kept"');

// How the record's function is given: the declaration, a partial application of a wider one, or a lambda.
function given(given, name, sig, params, body, arity) {
  const decl = `${name}Of : String, ${sig}\n${name}Of _ ${params} =\n${ind(body, 4)}\n`;
  if (given === 'direct') return { decl: `${name} : ${sig}\n${name} ${params} =\n${ind(body, 4)}\n`, ref: name };
  if (given === 'partial' && arity === 1) return { decl, ref: `(${name}Of "x"${' _'.repeat(arity)})` };
  const ps = Array.from({ length: arity }, (_, i) => `p${i}`).join(' ');
  return { decl, ref: `λ${ps} → ${name}Of "x" ${ps}` };
}

const ROLES = {
  // `browser`: a view whose outer handler shows the model; the inner click sends `Add` first.
  'dom-view': (T, twin, g) => {
    const v = given(g, 'view', `${T} → Html Msg`, 'model',
      `<div id="outer" onClick={λ_ → Debug.log (${shown(twin)}) Noop}>\n    <button id="add" onClick={λ_ → Add}>add</button>\n</div>`, 1);
    return {
      platform: 'platforms/browser', steps: 'click #add\nclick #add\n',
      src: `import Browser\nimport Html exposing (Html)\nimport List\n\n\ntype Msg\n    = Add\n    | Noop\n\n\n${MODEL}\n\ninit : ⊤ → Model\ninit ⊤ = ${INIT0}\n\n\nupdate : Msg, Model → Model\nupdate msg model =\n    case msg of\n        Add →\n            ${PUSH}\n\n        Noop →\n            model\n\n\n${v.decl}\n\nmain : Browser.Program\nmain = Browser.program { init = init, update = update, view = ${v.ref} }\n`,
    };
  },
  // `browser-tea`: the same view under `Tea.element`.
  'tea-view': (T, twin, g) => {
    const v = given(g, 'view', `${T} → Html Msg`, 'model',
      `<div id="outer" onClick={λ_ → Debug.log (${shown(twin)}) Noop}>\n    <button id="add" onClick={λ_ → Add}>add</button>\n</div>`, 1);
    return {
      platform: 'platforms/browser-tea', steps: 'click #add\nclick #add\n',
      src: `import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport List\nimport Sub exposing (Sub)\nimport Tea\n\n\ntype Msg\n    = Add\n    | Noop\n\n\n${MODEL}\n\ninit : ⊤ → Model × Cmd Msg\ninit ⊤ = ( ${INIT0}, Cmd.none )\n\n\nupdate : Msg, Model → Model × Cmd Msg\nupdate msg model =\n    case msg of\n        Add →\n            ( ${PUSH}, Cmd.none )\n\n        Noop →\n            ( model, Cmd.none )\n\n\n${v.decl}\n\nmain : Tea.Program\nmain = Tea.element { init = init, update = update, view = ${v.ref}, subscriptions = λ_ → Sub.none }\n`,
    };
  },
  // `browser-tea`: a `Tea.document` view.
  'tea-doc': (T, twin, g) => {
    const v = given(g, 'view', `${T} → Tea.Document Msg`, 'model',
      `{ title = "t"\n, body =\n    <div id="outer" onClick={λ_ → Debug.log (${shown(twin)}) Noop}>\n        <button id="add" onClick={λ_ → Add}>add</button>\n    </div>\n}`, 1);
    return {
      platform: 'platforms/browser-tea', steps: 'click #add\nclick #add\n',
      src: `import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport List\nimport Sub exposing (Sub)\nimport Tea\n\n\ntype Msg\n    = Add\n    | Noop\n\n\n${MODEL}\n\ninit : ⊤ → Model × Cmd Msg\ninit ⊤ = ( ${INIT0}, Cmd.none )\n\n\nupdate : Msg, Model → Model × Cmd Msg\nupdate msg model =\n    case msg of\n        Add →\n            ( ${PUSH}, Cmd.none )\n\n        Noop →\n            ( model, Cmd.none )\n\n\n${v.decl}\n\nmain : Tea.Program\nmain = Tea.document { init = init, update = update, view = ${v.ref}, subscriptions = λ_ → Sub.none }\n`,
    };
  },
  // `browser-tea`: a `Sub.listen` body keeps running across messages while its key stays.
  'tea-subs': (T, twin, g) => {
    const s = given(g, 'subscriptions', `${T} → Sub Msg`, 'model', 'Sub.listen "pulse" (pulse model 3 _) λs → Debug.log s Tick', 1);
    return {
      platform: 'platforms/browser-tea', steps: 'click #add\nadvance 150\nclick #add\nadvance 150\n',
      src: `import Browser\nimport Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport List\nimport Sub exposing (Sub)\nimport Tea\nimport Time\n\n\ntype Msg\n    = Add\n    | Tick\n\n\n${MODEL}\n\ninit : ⊤ → Model × Cmd Msg\ninit ⊤ = ( ${INIT0}, Cmd.none )\n\n\nupdate : Msg, Model → Model × Cmd Msg\nupdate msg model =\n    case msg of\n        Add →\n            ( ${PUSH}, Cmd.none )\n\n        Tick →\n            ( model, Cmd.none )\n\n\npulse : ${T}, Int, Browser.Send String → ⊤\npulse model k send =\n    Time.sleep (Time.millis 100)\n    send (${shown(twin)})\n    if k > 0 then pulse model (k - 1) send\n\n\n${s.decl}\n\nview : Model → Html Msg\nview model = <button id="add" onClick={Add}>{List.length model.items}</button>\n\n\nmain : Tea.Program\nmain = Tea.element { init = init, update = update, view = view, subscriptions = ${s.ref} }\n`,
    };
  },
  // `browser`, `Browser.hosted`: `update` keeps the model in `Task.soon`; `settle` writes it.
  'hosted-update': (T, twin, g) => {
    const u = given(g, 'update', `Host Msg, Msg, ${T} → ${T}`, '_ _ model',
      `_ = Task.soon λ⊤ → Debug.log (${shown(twin)}) ⊤\nmodel`, 3);
    return {
      platform: 'platforms/browser', steps: 'click #add\nclick #add\n',
      src: `import Browser exposing (Host)\nimport Html exposing (Html)\nimport List\nimport Task\n\n\ntype Msg\n    = Add\n\n\n${MODEL}\n\ninit : Host Msg → Model\ninit _ = ${INIT0}\n\n\n${u.decl}\n\nsettle : Host Msg, Model → Model\nsettle _ model = ${PUSH}\n\n\nview : Model → Html Msg\nview model = <button id="add" onClick={λ_ → Add}>{List.length model.items}</button>\n\n\nmain : Browser.Program\nmain = Browser.hosted { init = init, update = ${u.ref}, settle = settle, view = view }\n`,
    };
  },
  // `browser`, `Browser.hosted`: `settle` keeps the model in a fiber that sleeps; `update` writes it.
  'hosted-settle': (T, twin, g) => {
    const s = given(g, 'settle', `Host Msg, ${T} → ${T}`, '_ model',
      `_ = Task.spawn λ⊤ →\n    Time.sleep (Time.millis 100)\n    Debug.log (${shown(twin)}) ⊤\nmodel`, 2);
    return {
      platform: 'platforms/browser', steps: 'click #add\nclick #add\nadvance 200\n',
      src: `import Browser exposing (Host)\nimport Html exposing (Html)\nimport List\nimport Task\nimport Time\n\n\ntype Msg\n    = Add\n\n\n${MODEL}\n\ninit : Host Msg → Model\ninit _ = ${INIT0}\n\n\nupdate : Host Msg, Msg, Model → Model\nupdate _ _ model = ${PUSH}\n\n\n${s.decl}\n\nview : Model → Html Msg\nview model = <button id="add" onClick={λ_ → Add}>{List.length model.items}</button>\n\n\nmain : Browser.Program\nmain = Browser.hosted { init = init, update = update, settle = ${s.ref}, view = view }\n`,
    };
  },
};
for (const [role, mk] of Object.entries(ROLES)) for (const T of Object.keys(RTYPES)) for (const g of ['direct', 'partial', 'lambda']) for (const twin of ['live', 'dead']) {
  // A type variable or the model given through a lambda is the same type as `conc` there.
  if (g === 'lambda' && T !== 'row') continue;
  // `f a _` leaves one argument open: a function of two or more is given as a lambda instead.
  if (g === 'partial' && role.startsWith('hosted')) continue;
  const p = mk(RTYPES[T], twin, g);
  add(`row.${role}.${T}.${g}.${twin}`, { 'Main.beni': p.src }, p.platform, p.steps);
}

// ---- app: The Elm Architecture written the usual way ----------------------------------------------

// The writes `update` makes to the model's lists in place.
const WRITES = {
  push: 'items = List.push model.items model.n',
  set: 'items = List.set model.items 0 model.n',
  upd: 'rows = List.update model.rows 0 λr → List.push r model.n',
  both: 'items = List.push model.items model.n, rows = List.push model.rows [ model.n ]',
};
// What holds a list of the model (live) or holds nothing past the render (dead). Each gives the
// view's markup, extra declarations, and a message's arm.
const HOLDERS = {
  // A `For` row whose button sends its row (a list) in a message, and `update` writes it (live).
  rowmsg: {
    view: '<For each={model.rows} keyed={False}>{λr → <button class="row" onClick={Picked r}>{List.length r}</button>}</For>',
    arm: { live: 'Picked r → { model | picked = List.push r 0 }', dead: 'Picked r → { model | count = List.length r }' },
  },
  // A handler that closes over a list of the model, run when its click bubbles past `Add`.
  bubble: {
    inline: true,
    outer: { live: 'λ_ → Debug.log (Debug.toString model.items) Noop', dead: 'λ_ → Debug.log "outer" Noop' },
    view: '',
    arm: { live: 'Picked _ → model', dead: 'Picked _ → model' },
  },
  // A helper in a text hole, and `Html.map` of a child view over the model's rows.
  helper: {
    view: '{Html.map (child model.rows) Picked}<p>{total model.items}</p>',
    decls: 'total : List Int → Int\ntotal xs = List.sum xs\n\n\nchild : List (List Int) → Html (List Int)\nchild rs = <ul><For each={rs} keyed={False}>{λr → <li onClick={r}>{List.length r}</li>}</For></ul>\n',
    arm: { live: 'Picked r → { model | picked = List.push r 0 }', dead: 'Picked r → { model | count = List.length r }' },
  },
  // Text holes over the lists and a helper's argument; the message carries none of them.
  text: {
    inline: true,
    view: '<p>{total model.items}</p><p>{String.join (List.map model.rows Debug.toString) ";"}</p><button class="row" onClick={Picked [ 0 ]}>pick</button>',
    decls: 'total : List Int → Int\ntotal xs = List.sum xs\n',
    arm: { live: 'Picked r → { model | picked = List.push r model.n }', dead: 'Picked r → { model | count = List.length r }' },
  },
  // A `Show` whose body's button sends the shown list.
  show: {
    view: '<Show when={List.head model.rows} keyed={λr → List.length r}>{λr → <button class="row" onClick={Picked r}>{List.length r}</button>}</Show>',
    arm: { live: 'Picked r → { model | picked = List.push r 0 }', dead: 'Picked r → { model | count = List.length r }' },
  },
};
const APP_MODEL = 'type alias Model =\n    items : List Int\n    rows : List (List Int)\n    picked : List Int\n    count : Int\n    n : Int\n';
const APP_INIT = '{ items = [ 1 ], rows = [ [ 1 ], [ 2 ] ], picked = [], count = 0, n = 2 }';
function appSrc(platform, holder, write, twin) {
  const H = HOLDERS[holder];
  const outer = H.outer ? ` onClick={${H.outer[twin]}}` : '';
  const view = `view : Model → Html Msg\nview model =\n    <main id="outer"${outer}>\n        <button id="add" onClick={λ_ → Add}>add</button>\n        <p id="state">{Debug.toString model}</p>\n        ${H.view}\n    </main>\n`;
  const arms = `Add →\n    { model | ${WRITES[write]}, n = model.n + 1 }\n\n${H.arm[twin]}\n\nNoop →\n    model`;
  const msg = 'type Msg\n    = Add\n    | Picked (List Int)\n    | Noop\n';
  const decls = H.decls ? `${H.decls}\n\n` : '';
  if (platform === 'tea') {
    const upd = `update : Msg, Model → Model × Cmd Msg\nupdate msg model =\n    ( case msg of\n${ind(arms, 8)}\n    , Cmd.none\n    )\n`;
    return `import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport List\nimport Sub exposing (Sub)\nimport Tea\n\n\n${msg}\n\n${APP_MODEL}\n\ninit : ⊤ → Model × Cmd Msg\ninit ⊤ = ( ${APP_INIT}, Cmd.none )\n\n\n${upd}\n\n${decls}${view}\n\nmain : Tea.Program\nmain = Tea.element { init = init, update = update, view = view, subscriptions = λ_ → Sub.none }\n`;
  }
  const upd = `update : Msg, Model → Model\nupdate msg model =\n    case msg of\n${ind(arms, 8)}\n`;
  if (platform === 'dom') return `import Browser\nimport Html exposing (Html)\nimport List\n\n\n${msg}\n\n${APP_MODEL}\n\ninit : ⊤ → Model\ninit ⊤ = ${APP_INIT}\n\n\n${upd}\n\n${decls}${view}\n\nmain : Browser.Program\nmain = Browser.program { init = init, update = update, view = view }\n`;
  return `import Browser\nimport Html exposing (Html)\nimport List\nimport Tea\n\n\n${msg}\n\n${APP_MODEL}\n\n${upd}\n\n${decls}${view}\n\nmain : Tea.Program\nmain = Browser.mountAt (Tea.sandbox { init = λ⊤ → ${APP_INIT}, update = update, view = view }) "root"\n`;
}
const APP_PLATFORMS = { dom: 'platforms/browser', tea: 'platforms/browser-tea', inline: 'platforms/browser-inline' };
for (const [pl, dir] of Object.entries(APP_PLATFORMS)) for (const holder of Object.keys(HOLDERS)) for (const write of Object.keys(WRITES)) for (const twin of ['live', 'dead']) {
  // `browser-inline` compiles no `For` yet: only the holders without one.
  if (pl === 'inline' && !HOLDERS[holder].inline) continue;
  const clickRow = holder === 'helper' ? 'click li' : 'click .row';
  const steps = `${pl === 'inline' ? 'element "root"\n' : ''}click #add\n${holder === 'bubble' ? '' : `${clickRow}\n`}click #add\nclick #add\n`;
  add(`app.${pl}.${holder}.${write}.${twin}`, { 'Main.beni': appSrc(pl, holder, write, twin) }, dir, steps);
}

// ---- ssr: markup rendered on node ---------------------------------------------------------------

const SSR_HDR = 'import Html exposing (Html)\nimport Io\nimport List\nimport Node exposing (Program)\nimport Ref exposing (Ref)\nimport Ssr\n\n\nshow : List Int → String\nshow xs = Debug.toString xs\n\n\nkeepRow : Ref (List Int), List Int → Html msg\nkeepRow r l =\n    Ref.set r l\n    <li>{show l}</li>\n';
// Each makes markup `h` over the list `xs` (and the cell `r`), then the frame writes `xs` (live: it
// renders `h` after the write; dead: before).
const SSR = {
  hole: '<p>{show xs}</p>',
  len: '<p>{List.length xs}</p>',
  closure: '<p>{(λ⊤ → show xs) ⊤}</p>',
  forrow: '<ul><For each={[ xs ]} keyed={False}>{λl → <li>{show l}</li>}</For></ul>',
  forkeep: '<ul><For each={[ xs ]} keyed={False}>{λl → keepRow r l}</For></ul>',
  show: '<Show when={Just xs} keyed={λl → List.length l}>{λl → <b>{show l}</b>}</Show>',
  children: '<Card><i>{show xs}</i></Card>',
  attr: '<p title={show xs}>t</p>',
  nested: '<div>{<p>{show xs}</p>}</div>',
};
for (const [holder, mk] of Object.entries(SSR)) for (const twin of ['live', 'dead']) {
  const render = 'Debug.log (Ssr.render h) ⊤';
  const write = 'ys = List.push xs 9\nDebug.log (show ys) ⊤';
  const order = holder === 'forkeep' ? `${render}\n${write}${twin === 'live' ? '\nDebug.log (show (Ref.get r)) ⊤' : ''}` : (twin === 'live' ? `${write}\n${render}` : `${render}\n${write}`);
  const body = `r = Ref.make [ 0 ]\nxs = [ 1, 2 ]\nh = ${ind(mk, 4).trimStart()}\n${order}\nNode.done`;
  const files = { 'Main.beni': `${holder === 'children' ? 'import Card\n' : ''}${SSR_HDR}\n\nmain : Program\nmain =\n    Io.run λ⊤ →\n${ind(body, 8)}\n` };
  if (holder === 'children') files['Card.beni'] = 'import Html exposing (Html)\n\n\npub view : { children : Html msg } → Html msg\nview props = <section>{props.children}</section>\n';
  add(`ssr.${holder}.${twin}`, files, null, null);
}

// ---- fiber: fibers that wait ----------------------------------------------------------------------

const FIB_HDR = 'import Io\nimport List\nimport Node exposing (Program)\nimport Task\n\n\nshow : List Int → String\nshow xs = Debug.toString xs\n';
const FIBERS = {
  // A spawned fiber sleeps, then reads the list.
  spawn: (twin) => `xs = [ 1 ]\nf = Task.spawn λ⊤ →\n    Io.sleep 5\n    Debug.log (show ${twin === 'live' ? 'xs' : '[ 0 ]'}) ⊤\nys = List.push xs 2\nDebug.log (show ys) ⊤\nTask.join f`,
  // A scope's child reads the list after the parent has handed it back.
  scope: (twin) => `xs = [ 1 ]\nys =\n    Task.scope λs →\n        _ = Task.spawnIn s λ⊤ →\n            Io.sleep 5\n            Debug.log (show ${twin === 'live' ? 'xs' : '[ 0 ]'}) ⊤\n        xs\nzs = List.push ys 2\nDebug.log (show zs) ⊤\nIo.sleep 20`,
  // A fiber's answer is the list; the joiner writes it while another fiber still reads it.
  join: (twin) => `xs = [ 1 ]\nf = Task.spawn λ⊤ → xs\ng = Task.spawn λ⊤ →\n    Io.sleep 5\n    Debug.log (show ${twin === 'live' ? 'xs' : '[ 0 ]'}) ⊤\nys = List.push (Task.join f) 2\nDebug.log (show ys) ⊤\nTask.join g`,
  // `Task.soon` keeps a closure over a record that holds the list.
  soonrec: (twin) => `m = { xs = [ 1 ], n = 1 }\n_ = Task.soon λ⊤ → Debug.log (${twin === 'live' ? 'Debug.toString m' : '"soon"'}) ⊤\nys = List.push m.xs 2\nDebug.log (show ys) ⊤\nIo.sleep 5`,
  // A fold whose step spawns a reader of the accumulator.
  foldspawn: (twin) => `r = List.foldl [ 1, 2 ] [ 0 ] λi acc →\n    _ = Task.spawn λ⊤ →\n        Io.sleep 5\n        Debug.log (show ${twin === 'live' ? 'acc' : '[ 0 ]'}) ⊤\n    List.push acc i\nDebug.log (show r) ⊤\nIo.sleep 20`,
};
for (const [shape, mk] of Object.entries(FIBERS)) for (const twin of ['live', 'dead']) {
  add(`fiber.${shape}.${twin}`, { 'Main.beni': `${FIB_HDR}\n\nmain : Program\nmain =\n    Io.run λ⊤ →\n${ind(mk(twin), 8)}\n        Node.done\n` }, null, null);
}

// ---- top: a function that hands its own new list to its function parameter, then writes it ------

// `body` makes `xs`, hands it to `send`, writes it (live) or a copy of it (dead), and hands the
// result on. Where `body` goes, the code that calls it hands it a `send` that can keep what it is
// handed (the default use, kernel §6.8). Names: `top.<route>.<twin>`.
const TOP_BODY = (twin) => `body : Out → ⊤\nbody send =\n    xs = [ 1 ]\n    send xs\n    ys = List.push ${twin === 'live' ? 'xs' : '(List.copy xs)'} 2\n    send ys\n`;
const TOP_NODE = (route, twin) => {
  const keep = 'λl → Ref.set r (List.concat [ Ref.get r, [ l ] ])';
  const routes = {
    // A known keeper handed straight to `body`: the control, refused when live.
    direct: `body ${keep}`,
    // Through a cell: the code that calls `body` is unknown.
    ref: `cell = Ref.make body\ng = Ref.get cell\ng ${keep}`,
    // Through a record in a cell.
    refrec: `cell = Ref.make { run = body }\nh = Ref.get cell\nh.run ${keep}`,
    // Through `Maybe.withDefault` of a cell's contents.
    refmaybe: `cell = Ref.make (Just body)\ng = Maybe.withDefault (Ref.get cell) λ_ → ⊤\ng ${keep}`,
    // Through a list of functions in a cell.
    reflist: `cell = Ref.make [ body ]\nList.foldl (Ref.get cell) ⊤ λg _ → g ${keep}`,
  };
  return `import Io\nimport List\nimport Maybe\nimport Node exposing (Program)\nimport Ref exposing (Ref)\n\n\ntype alias Out =\n    List Int → ⊤\n\n\n${TOP_BODY(twin)}\n\nmain : Program\nmain =\n    Io.run λ⊤ →\n        r = Ref.make []\n${ind(routes[route], 8)}\n        Debug.log (Debug.toString (Ref.get r)) ⊤\n        Node.done\n`;
};
for (const route of ['direct', 'ref', 'refrec', 'refmaybe', 'reflist']) for (const twin of ['live', 'dead']) {
  add(`top.${route}.${twin}`, { 'Main.beni': TOP_NODE(route, twin) }, null, null);
}
// The same written as an application: a command's body takes the runtime's `send` under an alias of
// the program's own (`type alias Out = Browser.Send Msg`), which carries no word.
for (const alias of ['alias', 'word']) for (const how of ['perform', 'keyed', 'after']) for (const twin of ['live', 'dead']) {
  const T = alias === 'alias' ? 'Out' : 'Browser.Send Msg';
  const cmd = { perform: 'Cmd.perform body', keyed: 'Cmd.keyed "k" Cmd.Concurrent body', after: 'Cmd.afterRender body' }[how];
  const src = `import Browser\nimport Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport List\nimport Sub exposing (Sub)\nimport Tea\nimport Time\n\n\ntype Msg\n    = Add\n    | Got (List Int)\n\n\ntype alias Out =\n    Browser.Send Msg\n\n\ntype alias Model =\n    log : List (List Int)\n\n\ninit : ⊤ → Model × Cmd Msg\ninit ⊤ = ( { log = [] }, Cmd.none )\n\n\nbody : ${T} → ⊤\nbody send =\n    xs = [ 1 ]\n    send (Got xs)\n${how === 'after' ? '' : '    Time.sleep (Time.millis 10)\n'}    ys = List.push ${twin === 'live' ? 'xs' : '(List.copy xs)'} 2\n    send (Got ys)\n\n\nupdate : Msg, Model → Model × Cmd Msg\nupdate msg model =\n    case msg of\n        Add →\n            ( model, ${cmd} )\n\n        Got xs →\n            ( { model | log = List.push model.log xs }, Cmd.none )\n\n\nview : Model → Html Msg\nview model = <button id="add" onClick={Add}>{Debug.toString model.log}</button>\n\n\nmain : Tea.Program\nmain = Tea.element { init = init, update = update, view = view, subscriptions = λ_ → Sub.none }\n`;
  add(`top.tea-${how}.${alias}.${twin}`, { 'Main.beni': src }, 'platforms/browser-tea', 'click #add\nadvance 50\n');
}

// ---- write -----------------------------------------------------------------------------------------

fs.mkdirSync(out, { recursive: true });
const list = [];
for (const p of progs) {
  const d = path.join(out, p.name);
  fs.mkdirSync(d, { recursive: true });
  for (const [f, s] of Object.entries(p.files)) fs.writeFileSync(path.join(d, f), s);
  if (p.platform) fs.writeFileSync(path.join(d, 'PLATFORM'), `${p.platform}\n`);
  if (p.steps) fs.writeFileSync(path.join(d, 'steps'), p.steps);
  list.push(path.resolve(d));
}
fs.writeFileSync(path.join(out, 'LIST'), list.join('\n') + '\n');
console.log(`${list.length} programs`);
