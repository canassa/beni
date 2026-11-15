// answers-sends.mjs <outdir> [filter]: research report 143, the shapes that three precision fixes of
// ownership checker v3 newly accept, each with nasty variants. Four families:
//
// - `send.*`: a command's body (`Cmd.keyed`, `Cmd.perform`) sends a message on `browser-tea`, and `update`
//   stores the list the message holds in the model, which the page shows. A send now asks nothing of the
//   sender (kernel §6 rule 13). `dead` bodies send a top-level list, a list they read again, a list they
//   made and leave; `live` bodies push the list after they sent it (directly, after a sleep, through a
//   helper that sends, from a spawned fiber, through a second send of the same list), or send a list of
//   the model that `update` then pushes.
// - `cmdmap.*`: Conduit's `updateWith`, whose message function goes to `Cmd.map` where its answer
//   escapes, over a page message type of more locations than one query keeps in work. The function is a
//   constructor or a lambda that wraps (`dead`), or a lambda or a partial application that holds the
//   page's errors, or a page command that holds them (`live`); `update` then extends the errors in place.
// - `cell.*`: `Ref.update` of a record of 30 lists with a function whose answer the cell keeps: it makes a
//   record (`dead`), or puts a list of the frame at a late field, directly, through a helper, a partial
//   application, or a function it captured (`live`); the frame then pushes that list.
// - `alias.*`: a callback over an argument that holds one list at two places (`[ a, a ]`, a pair, a
//   tuple of the same list): it answers a new list (`dead`), the list it is handed, a captured list, the
//   answer of a captured function of its parameter, a record or a list around what it is handed, one of
//   two parts of a captured pair (`live`); every element of the result is then pushed in place.
//
// The last part of a name is the twin kind: `live` reads the old list after the write (must be refused or
// print the same), `dead` reads nothing after it (safe; a refusal is a precision loss). See
// bench/ownership-sweeps/README.md.
import fs from 'fs';
import path from 'path';

const [out, filter] = [process.argv[2], process.argv[3] || ''];
if (!out) { console.error('usage: node bench/ownership-sweeps/answers-sends.mjs <outdir> [filter]'); process.exit(2); }
const ind = (s, n) => s.split('\n').map((l) => (l ? ' '.repeat(n) + l : l)).join('\n');
const progs = [];
const add = (name, files, platform, steps) => {
  if (filter && !name.includes(filter)) return;
  progs.push({ name, files, platform, steps });
};
const TEA = 'platforms/browser-tea';

// ---- send: a command's body sends a list ----------------------------------------------------------------

const sendPage = (cmd, body, helpers = '') => `import Browser
import Cmd exposing (Cmd)
import Html exposing (Html)
import List
import Sub
import Task
import Tea
import Time


type Msg
    = Add
    | Fetch
    | Got (List Int)
    | Note Int


type Key
    = Load


type alias Model =
    items : List Int
    got : List Int
    notes : List Int


top : List Int
top = [ 7 ]
${helpers}

body : Browser.Send Msg → ⊤
body send =
${ind(body, 4)}


update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        Add →
            ( { model | items = List.push model.items (List.length model.items) }, Cmd.none )

        Fetch →
            ( model, ${cmd} )

        Got xs →
            ( { model | got = xs }, Cmd.none )

        Note n →
            ( { model | notes = [ …model.notes, n ] }, Cmd.none )


show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


view : Model → Html Msg
view model =
    <main>
        <button id="add" onClick={Add}>add</button>
        <button id="fetch" onClick={Fetch}>fetch</button>
        <p id="items">{show model.items}</p>
        <p id="got">{show model.got}</p>
        <p id="notes">{show model.notes}</p>
        <p id="top">{show top}</p>
    </main>


main : Tea.Program
main =
    Tea.element
        { init = λ⊤ → ( { items = [ 0 ], got = [], notes = [] }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = λ_ → Sub.none
        }
`;
const sendBodies = [
  ['top', 'dead', 'send (Got top)'],
  ['readafter', 'dead', 'xs = [ 1 ]\nsend (Got xs)\nsend (Note (List.length xs))'],
  ['fresh', 'dead', 'send (Got [ 1, 2 ])\nsend (Note 0)'],
  ['copyafter', 'dead', 'xs = [ 1 ]\nsend (Got xs)\nys = List.push (List.copy xs) 2\nsend (Note (List.length ys))'],
  ['pushafter', 'live', 'xs = [ 1 ]\nsend (Got xs)\nys = List.push xs 2\nsend (Note (List.length ys))'],
  ['pushsleep', 'live', 'xs = [ 1 ]\nsend (Got xs)\nTime.sleep (Time.millis 10)\nys = List.push xs 2\nsend (Note (List.length ys))'],
  ['helper', 'live', 'xs = [ 1 ]\ndeliver send xs\nys = List.push xs 2\nsend (Note (List.length ys))', '\n\ndeliver : Browser.Send Msg, List Int → ⊤\ndeliver s v = s (Got v)\n'],
  ['helperwrites', 'live', 'xs = [ 1 ]\nsendThenPush send xs\nsend (Note 0)', '\n\nsendThenPush : Browser.Send Msg, List Int → ⊤\nsendThenPush s v =\n    s (Got v)\n    s (Note (List.length (List.push v 2)))\n'],
  ['spawned', 'live', 'xs = [ 1 ]\nf = Task.spawn λ⊤ → send (Got xs)\nTask.join f\nys = List.push xs 2\nsend (Note (List.length ys))'],
  ['twice', 'live', 'xs = [ 1 ]\nsend (Got xs)\nsend (Got xs)\nys = List.push xs 2\nsend (Note (List.length ys))'],
  ['local', 'live', 'xs = [ 1 ]\npush = λ⊤ → List.push xs 2\nsend (Got xs)\nsend (Note (List.length (push ⊤)))'],
];
for (const [name, twin, body, helpers] of sendBodies) for (const [cname, cmd] of [['keyed', 'Cmd.keyed Load Cmd.Restart body'], ['perform', 'Cmd.perform body']]) {
  add(`send.${name}.${cname}.${twin}`, { 'Main.beni': sendPage(cmd, body, helpers ?? '') }, TEA, 'click #fetch\nadvance 50\nclick #add\nadvance 50\n');
}
// A body that sends a list of the model, which `update` then pushes.
add('send.model.live', { 'Main.beni': sendPage('Cmd.keyed Load Cmd.Restart λsend → send (Got model.items)', 'send (Note 0)').replace('            ( { model | got = xs }, Cmd.none )', '            ( { model | got = xs, items = List.push model.items 9 }, Cmd.none )') }, TEA, 'click #fetch\nadvance 50\nclick #add\nadvance 50\n');

// ---- cmdmap: Conduit's updateWith, a wide page message ------------------------------------------------

const ctors = Array.from({ length: 30 }, (_, i) => `    | M${i} (List String)`).join('\n');
const mapPage = (toMsg, extraMsg, pageCmd) => `import Cmd
import Html exposing (Html)
import Sub
import Tea


type alias Page =
    errors : List String


type PageMsg
    = Fail
    | Echo
${ctors}


pageUpdate : PageMsg, Page → Page × Cmd.Cmd PageMsg
pageUpdate msg page =
    case msg of
        Fail →
            ( { page | errors = page.errors ++ [ "failed" ] }, Cmd.none )

        Echo →
            ( page, ${pageCmd} )

        _ →
            ( page, Cmd.none )


type Model
    = Article Page


type Msg
    = GotPage PageMsg
    | Tagged PageMsg (List String)${extraMsg}


updateWith : (sub → Model), (subMsg → Msg), sub × Cmd.Cmd subMsg → Model × Cmd.Cmd Msg
updateWith toModel toMsg ( sub, subCmd ) = ( toModel sub, Cmd.map subCmd ⊤ toMsg )


update : Msg, Model → Model × Cmd.Cmd Msg
update msg model =
    case ( msg, model ) of
        ( GotPage sub, Article page ) →
            updateWith Article ${toMsg} (pageUpdate sub page)

        ( Tagged sub kept, Article page ) →
            updateWith Article GotPage (pageUpdate sub { page | errors = page.errors ++ [ String.join kept "+" ] })


view : Model → Html Msg
view model =
    case model of
        Article page →
            <main>
                <button id="fail" onClick={GotPage Fail}>fail</button>
                <button id="echo" onClick={GotPage Echo}>echo</button>
                <p id="errors">{String.join page.errors ","}</p>
            </main>


main : Tea.Program
main =
    Tea.element
        { init = λ⊤ → ( Article { errors = [ "first" ] }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = λ_ → Sub.none
        }
`;
const mapCases = [
  ['ctor', 'dead', 'GotPage', '', 'Cmd.task (λ⊤ → [ "e" ]) M3'],
  ['wraps', 'dead', '(λm → GotPage m)', '', 'Cmd.task (λ⊤ → [ "e" ]) M29'],
  ['freshcap', 'dead', '(λm → Tagged m [ "x" ])', '', 'Cmd.none'],
  ['captures', 'live', '(λm → Tagged m page.errors)', '', 'Cmd.task (λ⊤ → [ "e" ]) M29'],
  ['partial', 'live', '(Tagged _ page.errors)', '', 'Cmd.task (λ⊤ → [ "e" ]) M29'],
  ['pagecmd', 'live', 'GotPage', '', 'Cmd.task (λ⊤ → page.errors) M29'],
  ['inner', 'live', '(λm → wrap m)', '', 'Cmd.task (λ⊤ → [ "e" ]) M29'],
];
for (const [name, twin, toMsg, extra, pageCmd] of mapCases) {
  let src = mapPage(toMsg, extra, pageCmd);
  // `inner`: a local function that captures the errors answers the message.
  if (name === 'inner') src = src.replace('        ( GotPage sub, Article page ) →\n            updateWith', '        ( GotPage sub, Article page ) →\n            wrap = λm → Tagged m page.errors\n            updateWith');
  add(`cmdmap.${name}.${twin}`, { 'Main.beni': src }, TEA, 'click #echo\nadvance 50\nclick #fail\nadvance 50\nclick #fail\n');
}

// ---- cell: Ref.update of a wide record ------------------------------------------------------------------

const fields = Array.from({ length: 30 }, (_, i) => `f${i}`);
const cellProg = (decls, body) => `import List
import Node exposing (Program)
import Ref
import String


type alias Wide =
${fields.map((f) => `    ${f} : List Int`).join('\n')}


blank : ⊤ → Wide
blank ⊤ =
    { ${fields.map((f) => `${f} = []`).join(', ')} }
${decls}

show : List Int → String
show xs = String.join (List.map xs String.fromInt) ","


main : Program
main =
${ind(body, 4)}
`;
const late = 'f27';
const cellCases = [
  ['fresh', 'dead', '', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nRef.update cell λ_ → blank ⊤\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).${late}}"`],
  ['topfn', 'dead', '\n\nreset : Wide → Wide\nreset _ = blank ⊤\n', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nRef.update cell reset\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).${late}}"`],
  ['captured', 'live', '', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nRef.update cell λw → { w | ${late} = xs }\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).${late}}"`],
  ['first', 'live', '', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nRef.update cell λw → { w | f0 = xs }\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).f0}"`],
  ['helper', 'live', '\n\nput : List Int, Wide → Wide\nput k w = { w | f29 = k }\n', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nRef.update cell λw → put xs w\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).f29}"`],
  ['partial', 'live', '\n\nput : List Int, Wide → Wide\nput k w = { w | f29 = k }\n', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nRef.update cell (put xs _)\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).f29}"`],
  ['capfn', 'live', '', `xs = [ 1 ]\ng = λ⊤ → xs\ncell = Ref.make (blank ⊤)\nRef.update cell λw → { w | ${late} = g ⊤ }\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).${late}}"`],
  ['modify', 'live', '', `xs = [ 1 ]\ncell = Ref.make (blank ⊤)\nn = Ref.modify cell λw → ( 0, { w | ${late} = xs } )\nys = List.push xs 2\nNode.print "\${show ys} \${show (Ref.get cell).${late}} \${String.fromInt n}"`],
];
for (const [name, twin, decls, body] of cellCases) add(`cell.${name}.${twin}`, { 'Main.beni': cellProg(decls, body) }, null, null);

// ---- alias: a callback over an argument with one list twice -----------------------------------------------

const aliasProg = (decls, made) => `import List
import Maybe
import Node exposing (Program)
import String


show : List Int → String
show l = String.join (List.map l String.fromInt) ","


shows : List (List Int) → String
shows ls = String.join (List.map ls show) ";"


pushAll : List (List Int), Int → List (List Int)
pushAll ls n = List.map ls λl → List.push l n


myMap : List a, (a → b) → List b
myMap xs f =
    case xs of
        [ x, …rest ] →
            [ f x, …myMap rest f ]

        _ →
            []
${decls}

main : Program
main =
    a = [ 1 ]
    made = ${made}
    Node.print "\${shows made} \${show a}"
`;
const aliasCases = [
  ['map.fresh', 'dead', '', 'pushAll (List.map [ a, a ] λ_ → [ 9 ]) 2'],
  ['map.freshof', 'dead', '', 'pushAll (List.map [ a, a ] λx → [ List.length x ]) 2'],
  ['mymap.fresh', 'dead', '', 'pushAll (myMap [ a, a ] λ_ → [ 9 ]) 2'],
  ['indexed.fresh', 'dead', '', 'pushAll (List.indexedMap [ a, a ] λi _ → [ i ]) 2'],
  ['filtermap.fresh', 'dead', '', 'pushAll (List.filterMap [ a, a ] λ_ → Just [ 9 ]) 2'],
  ['pairs.fresh', 'dead', '', 'pushAll (List.map [ ( a, 1 ), ( a, 2 ) ] λ( _, k ) → [ k ]) 2'],
  ['map.ident', 'live', '', 'pushAll (List.map [ a, a ] λx → x) 2'],
  ['mymap.ident', 'live', '', 'pushAll (myMap [ a, a ] λx → x) 2'],
  ['map.captured', 'live', '', 'pushAll (List.map [ a, a ] λ_ → a) 2'],
  ['map.inner', 'live', '', 'pushAll (List.map [ a, a ] λx → (λy → y) x) 2'],
  ['map.capfn', 'live', '\n\nidentity : List Int → List Int\nidentity v = v\n', 'pushAll (List.map [ a, a ] λx → identity x) 2'],
  ['pairs.handed', 'live', '', 'pushAll (List.map [ ( a, 1 ), ( a, 2 ) ] λ( x, _ ) → x) 2'],
  ['map.part', 'live', '', 'pushAll (List.map [ 1, 2 ] λk → if k == 1 then a else a) 2'],
  ['map.default', 'live', '', 'pushAll (List.map [ a, a ] (Maybe.withDefault Nothing identity2)) 2', '\n\nidentity2 : List Int → List Int\nidentity2 v = v\n'],
  ['nested.outer', 'dead', '', 'List.concat (List.map (List.map [ a, a ] λx → [ x ]) λl → List.push l [ 0 ])'],
  ['nested.inner', 'live', '', 'pushAll (List.concat (List.map [ a, a ] λx → [ x ])) 2'],
];
for (const [name, twin, decls, made, more] of aliasCases) add(`alias.${name}.${twin}`, { 'Main.beni': aliasProg((decls ?? '') + (more ?? ''), made) }, null, null);

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
