// blind5d.mjs: research report 122, a fifth blind test (reader D). Programs written the way an application
// developer writes them, on the real platforms: The Elm Architecture on `browser` and `browser-tea`, with the
// model's lists kept by a message, a handler, a row, a helper, `Html.map`, a subscription, `settle`, a command,
// the history or `init`; and the record's functions given in nine ways. Then markup rendered on `node`, fibers
// that wait, `Dict`, `Random`, `Ref`, `Json`, two modules and a type with methods.
//
//   node bench/ownership-sweeps/blind5d.mjs <outdir> [filter]
//
// A program is `<family>.<shape…>.<twin>`:
//
// - `entry.<platform>.<keeper>.<form>.<twin>`: a page. `platform` is `tea` (`Tea.element`), `sandbox`
//   (`Tea.sandbox`), `doc` (`Tea.document`), `dom` (`Browser.program`) or `hosted` (`Browser.hosted`).
//   `keeper` is what holds a list of the model besides the model (below). `form` is how the function of the
//   record that holds the keeper is given to the runtime: `direct` (its name), `lam` (`λm → view m`),
//   `join` (`if True then view else view`), `proj` (a field of a top-level record), `partial` (`viewWith 0 _`),
//   `local` (a local of `main`), `call` (the answer of `pick view`), `case` (an arm of a `case`), `maybe`
//   (`Maybe.withDefault (Just view) view`). `live`: the keeper holds the model's list, and `update` then
//   pushes onto that list; `dead`: the keeper holds a copy.
// - `ssr.<shape>.<twin>`, `fiber.<shape>.<twin>`, `dict.…`, `random.…`, `ref.…`, `json.…`, `mods.…`,
//   `method.…`: the read and the write in one program on `node`.
//
// See bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/blind5d.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const names = [];
function emit(name, files, extra = {}) {
  if (!name.includes(filter)) return;
  const dir = path.join(out, name);
  fs.mkdirSync(dir, { recursive: true });
  for (const [f, src] of Object.entries(files)) fs.writeFileSync(path.join(dir, f), src);
  if (extra.platform) fs.writeFileSync(path.join(dir, 'PLATFORM'), extra.platform + '\n');
  if (extra.steps) fs.writeFileSync(path.join(dir, 'steps'), extra.steps);
  names.push(dir);
}

// ---- the entry ---------------------------------------------------------------------------------------------

// A platform: its imports, how `update` answers, how `init` is written and how the record is made.
const PLATFORMS = {
  tea: { dir: 'platforms/browser-tea', cmd: true, head: 'import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport Sub exposing (Sub)\nimport Task\nimport Tea\nimport Time\n', prog: 'Tea.Program', fields: ['init', 'update', 'view', 'subscriptions'], make: 'Tea.element' },
  sandbox: { dir: 'platforms/browser-tea', cmd: false, head: 'import Html exposing (Html)\nimport Tea\n', prog: 'Tea.Program', fields: ['init', 'update', 'view'], make: 'Tea.sandbox' },
  doc: { dir: 'platforms/browser-tea', cmd: true, doc: true, head: 'import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport Sub exposing (Sub)\nimport Task\nimport Tea\nimport Time\n', prog: 'Tea.Program', fields: ['init', 'update', 'view', 'subscriptions'], make: 'Tea.document' },
  dom: { dir: 'platforms/browser', cmd: false, head: 'import Browser\nimport Html exposing (Html)\n', prog: 'Browser.Program', fields: ['init', 'update', 'view'], make: 'Browser.program' },
  hosted: { dir: 'platforms/browser', cmd: false, hosted: true, head: 'import Browser exposing (Host)\nimport Html exposing (Html)\n', prog: 'Browser.Program', fields: ['init', 'update', 'settle', 'view'], make: 'Browser.hosted' },
};

// A keeper: the field of the record it lives in, the view's extra markup, `update`'s extra arms, `subscriptions`'
// body, `settle`'s body, `init`'s model, the steps, and the platforms it needs. `L` is the keeper's list in the
// live twin and `D` in the dead one. Every program pushes onto `items` (`#add`) or `rows`' first row (`#edit`).
const KEEPERS = {
  msg: { field: 'view', view: (L) => `<button id="k" onClick={Snap ${L('model.items')}}>k</button>`, steps: 'click #k\nclick #add\nclick #add\n' },
  twice: { field: 'view', view: (L) => `<button id="k" onClick={Snap ${L('model.items')}}>k</button>`, steps: 'click #k 2\nclick #add\n' },
  lam: { field: 'view', view: (L, live) => `<input id="k" onInput={λs → Snap ${live ? 'model.items' : '[ 0 ]'}} />`, steps: 'input #k "a"\nclick #add\nclick #add\n' },
  row: { field: 'view', view: (L) => `<For each={model.rows} keyed={False}>{λr → <button class="r" onClick={Snap ${L('r')}}>r</button>}</For>`, steps: 'click .r\nclick #edit\nclick #edit\n' },
  keyrow: { field: 'view', view: (L) => `<For each={model.rows} keyed={λr → String.fromInt (List.length r)}>{λr → <button class="r" onClick={Snap ${L('r')}}>r</button>}</For>`, steps: 'click .r\nclick #edit\nclick #edit\n' },
  rowfn: { field: 'view', view: (L, live) => `<For each={model.rows} keyed={False}>{${live ? 'rowButton' : 'rowCopy'}}</For>`, steps: 'click .r\nclick #edit\nclick #edit\n' },
  show: { field: 'view', view: (L) => `<Show when={List.head model.rows} keyed={λ_ → 0}>{λs → <button id="k" onClick={Snap ${L('s')}}>k</button>}</Show>`, steps: 'click #k\nclick #edit\nclick #edit\n' },
  rowmap: { field: 'view', view: (L) => `<For each={model.rows} keyed={False}>{λr → Html.map inner λ_ → Snap ${L('r')}}</For>`, steps: 'click #k\nclick #edit\nclick #edit\n' },
  nested: { field: 'view', view: (L) => `<For each={[ model.rows ]} keyed={False}>{λrs → <div><For each={rs} keyed={False}>{λr → <button class="r" onClick={Snap ${L('r')}}>r</button>}</For></div>}</For>`, steps: 'click .r\nclick #edit\nclick #edit\n' },
  helper: { field: 'view', view: (L) => `{snapButton ${L('model.items')}}`, steps: 'click #k\nclick #add\nclick #add\n' },
  map: { field: 'view', view: (L, live) => `{Html.map inner λ_ → Snap ${live ? 'model.items' : '[ 0 ]'}}`, steps: 'click #k\nclick #add\nclick #add\n' },
  sub: { field: 'subscriptions', needs: 'cmd', sub: (L, live) => `Time.every (Time.millis 100) λ_ → Snap ${live ? 'model.items' : '[ 0 ]'}`, steps: 'advance 150\nclick #add\nclick #add\n' },
  settle: { field: 'settle', needs: 'hosted', settle: (L) => `if model.snap then { model | saved = ${L('model.items')}, snap = False } else model`, steps: 'click #mark\nclick #add\nclick #add\n' },
  cmd: { field: 'update', needs: 'cmd', arm: (L) => `Ask →\n    kept = ${L('model.items')}\n    ( model, Cmd.task (later kept _) Snap )`, steps: 'click #ask\nclick #add\nadvance 200\nclick #add\n' },
  hist: { field: 'update', arm: (L) => `Keep →\n    ${R(`{ model | history = List.push model.history ${L('model.items')} }`)}`, steps: 'click #keep\nclick #add\nclick #add\n' },
  init: { field: 'init', init: (L) => `xs = List.copy [ 1, 2 ]\n{ items = xs, saved = ${L('xs')}, rows = [ [ 1 ], [ 2 ] ], history = [], snap = False, n = 3 }`, steps: 'click #add\nclick #add\n' },
};
let R = (x) => x; // set per platform: an `update` answer

const FORMS = ['direct', 'lam', 'join', 'proj', 'partial', 'local', 'call', 'case', 'maybe'];

function entryProgram(pn, kn, form, twin) {
  const p = PLATFORMS[pn];
  const k = KEEPERS[kn];
  if (k.needs === 'cmd' && !p.cmd) return null;
  if (k.needs === 'hosted' && !p.hosted) return null;
  if (k.field === 'settle' && !p.hosted) return null;
  if ((k.field === 'update' || k.field === 'init') && form !== 'direct') return null;
  const L = twin === 'live' ? (x) => x : (x) => `(List.copy ${x})`;
  R = p.cmd ? (x) => `( ${x}, Cmd.none )` : (x) => x;
  const hostP = p.hosted ? '_ ' : '';
  const hostT = p.hosted ? 'Host Msg, ' : '';
  const upT = p.cmd ? 'Model × Cmd Msg' : 'Model';
  const arms = [
    `Add →\n    ${R('{ model | items = List.push model.items model.n, n = model.n + 1 }')}`,
    `Edit →\n    n = model.n\n    ${R('{ model | rows = List.update model.rows 0 λr → List.push r n, n = n + 1 }')}`,
    `Snap xs →\n    ${R('{ model | saved = xs }')}`,
    `Mark →\n    ${R('{ model | snap = True }')}`,
  ];
  if (k.arm) arms.push(k.arm(L));
  if (kn !== 'cmd') arms.push(`Ask →\n    ${R('model')}`);
  if (kn !== 'hist') arms.push(`Keep →\n    ${R('model')}`);
  const update = `update : ${hostT}Msg, Model → ${upT}\nupdate ${hostP}msg model =\n    case msg of\n${ind(arms.join('\n\n'), 8)}\n`;
  const initModel = k.init ? k.init(L) : '{ items = List.copy [ 1, 2 ], saved = [], rows = [ [ 1 ], [ 2 ] ], history = [], snap = False, n = 3 }';
  const initArg = p.hosted ? '_' : '⊤';
  const initT = p.hosted ? 'Host Msg' : '⊤';
  const initBody = p.cmd ? `( ${initModel.includes('\n') ? '\n' + ind(initModel, 4) + '\n' : initModel}, Cmd.none )` : initModel;
  const init = p.cmd && initModel.includes('\n')
    ? `init : ${initT} → ${upT}\ninit ${initArg} =\n${ind(initModel.replace(/\n([^\n]*)$/, '\n( $1, Cmd.none )'), 4)}\n`
    : `init : ${initT} → ${upT}\ninit ${initArg} =\n${ind(initBody, 4)}\n`;
  const extraView = k.view ? k.view(L, twin === 'live') : '';
  const body = `<main>
    <button id="add" onClick={Add}>add</button>
    <button id="edit" onClick={Edit}>edit</button>
    <button id="mark" onClick={Mark}>mark</button>
    <button id="ask" onClick={Ask}>ask</button>
    <button id="keep" onClick={Keep}>keep</button>
    <p id="items">{show model.items}</p>
    <p id="saved">{show model.saved}</p>
    <p id="rows">{String.join (List.map model.rows show) "|"}</p>
    <p id="hist">{String.join (List.map model.history show) "|"}</p>
    ${extraView}
</main>`;
  const viewT = p.doc ? 'Tea.Document Msg' : 'Html Msg';
  const viewBody = p.doc ? `{ title = "t", body =\n${ind(body, 4)}\n}` : body;
  const view = `view : Model → ${viewT}\nview model =\n${ind(viewBody, 4)}\n\n\nviewWith : Int, Model → ${viewT}\nviewWith _ model = view model\n`;
  const subs = p.cmd ? `subscriptions : Model → Sub Msg\nsubscriptions model =\n    ${k.sub ? k.sub(L, twin === 'live') : 'Sub.none'}\n\n\nsubscriptionsWith : Int, Model → Sub Msg\nsubscriptionsWith _ model = subscriptions model\n` : '';
  const settle = p.hosted ? `settle : Host Msg, Model → Model\nsettle _ model =\n    ${k.settle ? k.settle(L) : 'model'}\n\n\nsettleOf : Int → (Host Msg, Model → Model)\nsettleOf _ = settle\n` : '';
  const ty = { view: `Model → ${viewT}`, subscriptions: 'Model → Sub Msg', settle: 'Host Msg, Model → Model' }[k.field];
  const fname = k.field;
  const lamOf = { view: 'λm → view m', subscriptions: 'λm → subscriptions m', settle: 'λh m → settle h m' }[fname];
  const partialOf = { view: 'viewWith 0 _', subscriptions: 'subscriptionsWith 0 _', settle: 'settleOf 0' }[fname];
  let pre = '';
  let local = '';
  let value = fname;
  switch (form) {
    case 'direct': break;
    case 'lam': value = lamOf; break;
    case 'join': value = `if True then ${fname} else ${fname}`; break;
    case 'proj': pre = `fns : { f : ${ty} }\nfns = { f = ${fname} }\n\n\n`; value = 'fns.f'; break;
    case 'partial': value = partialOf; break;
    case 'local': local = `f = ${fname}\n`; value = 'f'; break;
    case 'call': pre = `pick : (${ty}) → (${ty})\npick g = g\n\n\n`; value = `pick ${fname}`; break;
    case 'case': value = `case 0 of\n    _ →\n        ${fname}`; break;
    case 'maybe': value = `Maybe.withDefault (Just ${fname}) ${fname}`; break;
  }
  const rec = p.fields.map((fl) => {
    if (fl === fname) return `${fl} = ${value.includes('\n') ? '\n' + ind(value, 4) : value}`;
    return `${fl} = ${fl}`;
  });
  const record = `{ ${rec.map((r) => r.replace(/\n/g, '\n  ')).join('\n, ')}\n}`;
  const main = `main : ${p.prog}\nmain =\n${ind(local + `${p.make}\n${ind(record, 4)}`, 4)}\n`;
  const src = `${p.head}import List
import Maybe
import String


type Msg
    = Add
    | Edit
    | Snap (List Int)
    | Mark
    | Ask
    | Keep


type Inner
    = Clicked


type alias Model =
    items : List Int
    saved : List Int
    rows : List (List Int)
    history : List (List Int)
    snap : Bool
    n : Int


show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


snapButton : List Int → Html Msg
snapButton xs = <button id="k" onClick={Snap xs}>k</button>


inner : Html Inner
inner = <button id="k" onClick={Clicked}>k</button>


rowButton : List Int → Html Msg
rowButton r = <button class="r" onClick={Snap r}>r</button>


rowCopy : List Int → Html Msg
rowCopy r = <button class="r" onClick={Snap (List.copy r)}>r</button>

${p.cmd ? `
later : List Int, ⊤ → List Int
later xs ⊤ =
    Time.sleep (Time.millis 100)
    xs

` : ''}
${init}

${update}

${view}

${subs ? subs + '\n\n' : ''}${settle ? settle + '\n\n' : ''}${pre}${main}`;
  return { files: { 'Main.beni': src.replace(/\n{4,}/g, '\n\n\n') }, extra: { platform: p.dir, steps: k.steps } };
}

for (const pn of Object.keys(PLATFORMS)) for (const kn of Object.keys(KEEPERS)) for (const form of FORMS) for (const twin of ['live', 'dead']) {
  const prog = entryProgram(pn, kn, form, twin);
  if (prog) emit(`entry.${pn}.${kn}.${form}.${twin}`, prog.files, prog.extra);
}

// ---- the model's own shape ---------------------------------------------------------------------------------
//
// `model.<platform>.<shape>.<keeper>.<twin>`: the model is a record, a pair, a triple or a constructor, and
// `update` answers it alone or in a pair with a command. `keeper`: `twice`, `update` answers the first list at
// both places; `cmd`, the command keeps it and gives it back later; `msg`, the view puts it in a message.

const SHAPES = {
  rec: { ty: 'type alias Model =\n    items : List Int\n    saved : List Int\n', pat: 'model', a: 'model.items', b: 'model.saved', mk: (a, b) => `{ items = ${a}, saved = ${b} }` },
  pair: { ty: 'type alias Model =\n    List Int × List Int\n', pat: '( items, saved )', a: 'items', b: 'saved', mk: (a, b) => `( ${a}, ${b} )` },
  triple: { ty: 'type alias Model =\n    List Int × List Int × Int\n', pat: '( items, saved, _ )', a: 'items', b: 'saved', mk: (a, b) => `( ${a}, ${b}, 0 )` },
  ctor: { ty: 'type Model\n    = Model (List Int) (List Int)\n', pat: '(Model items saved)', a: 'items', b: 'saved', mk: (a, b) => `Model ${a.includes(' ') ? `(${a})` : a} ${b.includes(' ') ? `(${b})` : b}` },
};
const MPLATFORMS = {
  tea: { dir: 'platforms/browser-tea', cmd: true, head: 'import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport Sub\nimport Tea\nimport Time\n', prog: 'Tea.Program', make: 'Tea.element', extra: 'subscriptions = λ_ → Sub.none' },
  doc: { dir: 'platforms/browser-tea', cmd: true, doc: true, head: 'import Cmd exposing (Cmd)\nimport Html exposing (Html)\nimport Sub\nimport Tea\nimport Time\n', prog: 'Tea.Program', make: 'Tea.document', extra: 'subscriptions = λ_ → Sub.none' },
  sandbox: { dir: 'platforms/browser-tea', cmd: false, head: 'import Html exposing (Html)\nimport Tea\n', prog: 'Tea.Program', make: 'Tea.sandbox' },
  dom: { dir: 'platforms/browser', cmd: false, head: 'import Browser\nimport Html exposing (Html)\n', prog: 'Browser.Program', make: 'Browser.program' },
  hosted: { dir: 'platforms/browser', cmd: false, hosted: true, head: 'import Browser exposing (Host)\nimport Html exposing (Html)\n', prog: 'Browser.Program', make: 'Browser.hosted', extra: 'settle = λ_ m → m' },
};
for (const [pn, p] of Object.entries(MPLATFORMS)) for (const [sn, sh] of Object.entries(SHAPES)) for (const kn of ['twice', 'cmd', 'msg']) for (const twin of ['live', 'dead']) {
  if (kn === 'cmd' && !p.cmd) continue;
  const keep = twin === 'live' ? sh.a : `(List.copy ${sh.a})`;
  const ans = (x) => (p.cmd ? `( ${x}, Cmd.none )` : x);
  const arms = [
    `Add →\n    ${ans(sh.mk(`List.push ${sh.a} 3`, sh.b))}`,
    kn === 'twice' ? `Snap →\n    ${ans(sh.mk(sh.a, keep))}` : kn === 'cmd' ? `Snap →\n    ( ${sh.mk(sh.a, sh.b)}, Cmd.task (later ${keep}) Got )` : `Snap →\n    ${ans(sh.mk(sh.a, sh.b))}`,
    `Got xs →\n    ${ans(sh.mk(sh.a, 'xs'))}`,
  ];
  const upT = p.cmd ? 'Model × Cmd Msg' : 'Model';
  const host = p.hosted ? 'Host Msg, ' : '';
  const body = `<main>\n    <button id="add" onClick={Add}>add</button>\n    <button id="snap" onClick={${kn === 'msg' ? `Got ${keep}` : 'Snap'}}>snap</button>\n    <p>{List.length ${sh.a}}/{List.length ${sh.b}}</p>\n</main>`;
  const viewT = p.doc ? 'Tea.Document Msg' : 'Html Msg';
  const viewBody = p.doc ? `{ title = "t", body =\n${ind(body, 4)}\n}` : body;
  const init0 = sh.mk('List.copy [ 1, 2 ]', '[]');
  const initV = p.hosted ? `λ_ → ${init0}` : p.cmd ? `λ⊤ → ( ${init0}, Cmd.none )` : `λ⊤ → ${init0}`;
  const fields = [`init = ${initV}`, 'update = update', 'view = view', ...(p.extra ? [p.extra] : [])];
  const src = `${p.head}import List


type Msg
    = Add
    | Snap
    | Got (List Int)


${sh.ty}
${p.cmd ? `
later : List Int → ⊤ → List Int
later xs = λ⊤ →
    Time.sleep (Time.millis 100)
    xs

` : ''}
update : ${host}Msg, Model → ${upT}
update ${p.hosted ? '_ ' : ''}msg ${sh.pat} =
    case msg of
${ind(arms.join('\n\n'), 8)}


view : Model → ${viewT}
view ${sh.pat} =
${ind(viewBody, 4)}


main : ${p.prog}
main =
    ${p.make}
        { ${fields.join('\n        , ')}
        }
`;
  emit(`model.${pn}.${sn}.${kn}.${twin}`, { 'Main.beni': src.replace(/\n{4,}/g, '\n\n\n') }, { platform: p.dir, steps: kn === 'cmd' ? 'click #snap\nclick #add\nadvance 200\nclick #add\n' : 'click #snap\nclick #add\nclick #add\n' });
}

// ---- programs on node ---------------------------------------------------------------------------------------

const NODE_HEAD = `import Dict exposing (Dict)
import Html exposing (Html)
import Io
import Json
import List
import Maybe
import Node exposing (Program)
import Random.Pcg as Pcg
import Ref exposing (Ref)
import Result
import Ssr
import String
import Task


show : List Int → String
show l = String.join (List.map l String.fromInt) ","


shows : List (List Int) → String
shows l = String.join (List.map l show) "|"


card : List Int → Html msg
card xs = <p>{show xs}</p>
`;

// One body each: `W` is where the write goes (`ys = List.push xs 3` or a write of the shape's own), `T` the
// twin's choice of list (`xs` live, `List.copy xs` dead). Each prints what it read and what it wrote.
const NODE = {
  // markup that holds the list until it renders
  'ssr.local': (T) => `xs = List.copy [ 1, 2 ]\nh = card ${T('xs')}\nys = List.push xs 3\nNode.print "\${Ssr.render h}/\${show ys}"`,
  'ssr.lazyfn': (T) => `xs = List.copy [ 1, 2 ]\nc = ${T('xs')}\nmk = λ⊤ → card c\nys = List.push xs 3\nNode.print "\${Ssr.render (mk ⊤)}/\${show ys}"`,
  'ssr.maybe': (T) => `xs = List.copy [ 1, 2 ]\nh = Maybe.map (Just ${T('xs')}) card\nys = List.push xs 3\ntxt = Maybe.withDefault (Maybe.map h Ssr.render) "-"\nNode.print "\${txt}/\${show ys}"`,
  'ssr.list': (T) => `xs = List.copy [ 1, 2 ]\nhs = List.map [ 1, 2 ] λ_ → card ${T('xs')}\nys = List.push xs 3\ntxt = String.join (List.map hs Ssr.render) "+"\nNode.print "\${txt}/\${show ys}"`,
  'ssr.ref': (T) => `xs = List.copy [ 1, 2 ]\nr = Ref.make (card ${T('xs')})\nys = List.push xs 3\nNode.print "\${Ssr.render (Ref.get r)}/\${show ys}"`,
  'ssr.for': (T) => `xs = List.copy [ 1, 2 ]\nc = ${T('xs')}\nh = <ul><For each={c} keyed={False}>{λx → <li>{x}</li>}</For></ul>\nys = List.push xs 3\nNode.print "\${Ssr.render h}/\${show ys}"`,
  'ssr.rowcap': (T) => `xs = List.copy [ 1, 2 ]\nc = ${T('xs')}\nh = <ul><For each={[ 7 ]} keyed={False}>{λx → card c}</For></ul>\nys = List.push xs 3\nNode.print "\${Ssr.render h}/\${show ys}"`,
  // fibers that wait
  'fiber.spawn': (T) => `xs = List.copy [ 1, 2 ]\nkeep = ${T('xs')}\nfb = Task.spawn λ⊤ →\n    Io.sleep 5\n    show keep\nys = List.push xs 3\nNode.printLines [ Task.join fb, show ys ]`,
  'fiber.helper': (T) => `xs = List.copy [ 1, 2 ]\nfb = watch ${T('xs')}\nys = List.push xs 3\nNode.printLines [ Task.join fb, show ys ]`,
  'fiber.race': (T) => `xs = List.copy [ 1, 2 ]\nkeep = ${T('xs')}\nslow = λ⊤ →\n    Io.sleep 50\n    "slow"\nr = Task.race slow λ⊤ →\n    Io.sleep 1\n    show keep\nys = List.push xs 3\nNode.printLines [ r, show ys ]`,
  'fiber.after': (T) => `xs = List.copy [ 1, 2 ]\nkeep = ${T('xs')}\nfb = Task.spawn λ⊤ →\n    Io.sleep 5\n    show keep\na = Task.join fb\nys = List.push xs 3\nNode.printLines [ a, show ys ]`,
  'fiber.foreach': (T) => `rows = [ List.copy [ 1 ], List.copy [ 2 ] ]\nout = Task.forEach ${T('rows')} 2 λr →\n    Io.sleep 1\n    List.length r\nzs = List.update rows 0 λr → List.push r 9\nNode.printLines [ show out, shows zs ]`,
  'fiber.deferred': (T) => `xs = List.copy [ 1, 2 ]\nd = Deferred.make ⊤\n_ = Deferred.complete d ${T('xs')}\nys = List.push xs 3\nNode.printLines [ show (Deferred.wait d), show ys ]`,
  'fiber.queue': (T) => `xs = List.copy [ 1, 2 ]\nq = Queue.unbounded ⊤\n_ = Queue.offer q ${T('xs')}\nys = List.push xs 3\nNode.printLines [ show (Maybe.withDefault (Queue.poll q) []), show ys ]`,
  // Dict and Random
  'dict.get': (T) => `xs = List.copy [ 1, 2 ]\nd = Dict.insert Dict.empty 1 ${T('xs')}\nys = List.push xs 3\nNode.printLines [ show (Maybe.withDefault (Dict.get d 1) []), show ys ]`,
  'dict.update': (T) => `xs = List.copy [ 1, 2 ]\nd = Dict.fromList [ ( 1, xs ), ( 2, ${T('xs')} ) ]\nd2 = Dict.update d 1 λm → Maybe.map m λl → List.push l 3\nNode.printLines [ show (Maybe.withDefault (Dict.get d2 2) []), show (Maybe.withDefault (Dict.get d2 1) []) ]`,
  'dict.values': (T) => `d = Dict.fromList [ ( 1, List.copy [ 1, 2 ] ) ]\nvs = Dict.values d\nkept = ${T('vs')}\nd2 = Dict.update d 1 λm → Maybe.map m λl → List.push l 3\nNode.printLines [ shows kept, show (Maybe.withDefault (Dict.get d2 1) []) ]`,
  'dict.fold': (T) => `d = Dict.fromList [ ( 1, List.copy [ 1, 2 ] ) ]\nall = Dict.foldl d [] λ_ v acc → List.push acc ${T('v')}\nd2 = Dict.update d 1 λm → Maybe.map m λl → List.push l 3\nNode.printLines [ shows all, show (Maybe.withDefault (Dict.get d2 1) []) ]`,
  'random.uniform': (T) => `rows = [ List.copy [ 1 ], List.copy [ 2 ] ]\n( picked, _ ) = Pcg.step (Pcg.uniform [ 0 ] ${T('rows')}) (Pcg.initialSeed 3)\nqs = List.push picked 9\nNode.printLines [ shows rows, show qs ]`,
  'random.constant': (T) => `xs = List.copy [ 1, 2 ]\n( got, _ ) = Pcg.step (Pcg.constant ${T('xs')}) (Pcg.initialSeed 3)\nys = List.push got 9\nNode.printLines [ show xs, show ys ]`,
  'random.map': (T) => `xs = List.copy [ 1, 2 ]\n( got, _ ) = Pcg.step (Pcg.map (Pcg.int 0 1) λ_ → ${T('xs')}) (Pcg.initialSeed 3)\nys = List.push got 9\nNode.printLines [ show xs, show ys ]`,
  'ssr.rowkeep': (T) => `rows = [ List.copy [ 1 ], List.copy [ 2 ] ]\nseen = Ref.make []\nh = <ul><For each={rows} keyed={False}>{λr → keepRow seen ${T('r')}}</For></ul>\ntxt = Ssr.render h\nzs = List.update rows 1 λr → List.push r 9\nNode.printLines [ txt, shows (Ref.get seen), shows zs ]`,
  'ssr.showkeep': (T) => `rows = [ List.copy [ 1 ], List.copy [ 2 ] ]\nseen = Ref.make []\nh = <Show when={List.head rows} keyed={λ_ → 0}>{λr → keepRow seen ${T('r')}}</Show>\ntxt = Ssr.render h\nzs = List.update rows 0 λr → List.push r 9\nNode.printLines [ txt, shows (Ref.get seen), shows zs ]`,
  'ssr.keykeep': (T) => `rows = [ List.copy [ 1 ], List.copy [ 2 ] ]\nseen = Ref.make []\nh = <ul><For each={rows} keyed={λr → keyOf seen ${T('r')}}>{λr → <li>{show r}</li>}</For></ul>\ntxt = Ssr.render h\nzs = List.update rows 1 λr → List.push r 9\nNode.printLines [ txt, shows (Ref.get seen), shows zs ]`,
  'ssr.showkeykeep': (T) => `rows = [ List.copy [ 1 ], List.copy [ 2 ] ]\nseen = Ref.make []\nh = <Show when={List.head rows} keyed={λr → List.length (keyRow seen ${T('r')})}>{λr → <li>{show r}</li>}</Show>\ntxt = Ssr.render h\nzs = List.update rows 0 λr → List.push r 9\nNode.printLines [ txt, shows (Ref.get seen), shows zs ]`,
  'json.encode': (T) => `xs : List Int\nxs = List.copy [ 1, 2 ]\ns = Result.withDefault (Json.encode ${T('xs')}) "-"\nys = List.push xs 3\nNode.printLines [ s, show ys ]`,
  'json.decode': (T) => `got : List Int\ngot = Result.withDefault (Json.decode "[1,2]") []\nkept = ${T('got')}\nys = List.push got 3\nNode.printLines [ show kept, show ys ]`,
  // Ref cells
  'ref.get': (T) => `r = Ref.make (List.copy [ 1, 2 ])\nxs = ${T('(Ref.get r)')}\nRef.update r λl → List.push l 3\nNode.printLines [ show xs, show (Ref.get r) ]`,
  'ref.modify': (T) => `r = Ref.make (List.copy [ 1, 2 ])\nold = Ref.modify r λl → ( ${T('l')}, List.push l 3 )\nNode.printLines [ show old, show (Ref.get r) ]`,
  'ref.set': (T) => `xs = List.copy [ 1, 2 ]\nr = Ref.make []\nRef.set r ${T('xs')}\nys = List.push xs 3\nNode.printLines [ show (Ref.get r), show ys ]`,
};

const NODE_FNS = `
keyOf : Ref (List (List Int)), List Int → String
keyOf seen r =
    Ref.set seen [ r ]
    show r


keyRow : Ref (List (List Int)), List Int → List Int
keyRow seen r =
    Ref.set seen [ r ]
    r


keepRow : Ref (List (List Int)), List Int → Html msg
keepRow seen r =
    Ref.set seen [ r ]
    <li>{show r}</li>


watch : List Int → Task.Fiber String
watch xs = Task.spawn λ⊤ →
    Io.sleep 5
    show xs
`;

for (const [shape, body] of Object.entries(NODE)) for (const twin of ['live', 'dead']) {
  const T = twin === 'live' ? (x) => x : (x) => `(List.copy ${x})`;
  const fiber = shape.startsWith('fiber.') || shape.startsWith('ssr.');
  const imports = NODE_HEAD.replace('import Dict', 'import Deferred\nimport Dict').replace('import Random.Pcg as Pcg', 'import Queue\nimport Random.Pcg as Pcg');
  const src = `${imports}${NODE_FNS}\n\nmain : Program\nmain = Io.run λ⊤ →\n${ind(body(T), 4)}\n`;
  void fiber;
  emit(`${shape}.${twin}`, { 'Main.beni': src });
}

// ---- two modules, a type with methods --------------------------------------------------------------------------

const STACK = `import List


pub type Stack
    = Stack (List Int) Int


pub empty : Stack
empty = Stack [] 0


pub push : Stack, Int → Stack
push (Stack xs n) x = Stack (List.push xs x) (n + 1)


pub items : Stack → List Int
items (Stack xs _) = xs


pub top : Stack → Maybe Int
top (Stack xs _) = List.last xs


pub withAll : List Int → Stack
withAll xs = Stack xs (List.length xs)
`;

const METHOD = {
  'items': (T) => `s = (Stack.withAll (List.copy [ 1, 2 ])).push 3\nseen = ${T('s.items')}\ns2 = s.push 4\nNode.printLines [ show seen, show s2.items ]`,
  'shared': (T) => `xs = List.copy [ 1, 2 ]\ns = Stack.withAll ${T('xs')}\ns2 = s.push 4\nNode.printLines [ show xs, show s2.items ]`,
  'twostacks': (T) => `xs = List.copy [ 1, 2 ]\na = Stack.withAll xs\nb = Stack.withAll ${T('xs')}\na2 = a.push 4\nNode.printLines [ show b.items, show a2.items ]`,
  'pair': (T) => `s = Stack.withAll (List.copy [ 1, 2 ])\np = ( s, ${T('s.items')} )\ns2 = s.push 4\n( _, old ) = p\nNode.printLines [ show old, show s2.items ]`,
  'fold': (T) => `s = List.foldl [ 1, 2, 3 ] (Stack.withAll (List.copy [ 0 ])) λx acc → acc.push x\nkept = ${T('s.items')}\ns2 = s.push 9\nNode.printLines [ show kept, show s2.items ]`,
};

for (const [shape, body] of Object.entries(METHOD)) for (const twin of ['live', 'dead']) {
  const T = twin === 'live' ? (x) => x : (x) => `(List.copy ${x})`;
  const src = `import List\nimport Node exposing (Program)\nimport Stack exposing (Stack)\nimport String\n\n\nshow : List Int → String\nshow l = String.join (List.map l String.fromInt) ","\n\n\nmain : Program\nmain =\n${ind(body(T), 4)}\n`;
  emit(`method.${shape}.${twin}`, { 'Main.beni': src, 'Stack.beni': STACK });
}

fs.writeFileSync(path.join(out, 'LIST'), names.join('\n') + '\n');
console.log(`${names.length} programs in ${out}`);
