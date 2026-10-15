import fs from 'node:fs';import {application} from './catalogue.mjs';import {writeApp} from './generate.mjs';
const base=application(1,17,'cluster'),cases=[];
const sources={
 'whole-model-alias':`import Html exposing (Html)

pub type alias Model =
    rows : List Int
    snapshot : List Int

identity : Model → Model
identity model = model
pub type Msg = Reverse
pub init : ⊤ → Model
init ⊤ = { rows = [ 1, 2, 3 ], snapshot = [] }
pub update : Msg, Model → Model
update msg model =
    case msg of
        Reverse → { model | rows = List.reverse model.rows, snapshot = (identity model).rows }
number : List Int → Int
number rows = List.foldl rows 0 (λn total → total * 10 + n)
pub view : Model → Html Msg
view model = <section data-shape="adversarial"><button id="reverse" onClick={Reverse}>Reverse</button><output id="rowsOutput">{number model.rows}</output><output id="snapshotOutput">{number model.snapshot}</output></section>
`,
 'cross-arm-alias':`import Html exposing (Html)

pub type alias Model =
    rows : List Int
    snapshot : List Int

pub type Msg = Capture | Reverse
pub init : ⊤ → Model
init ⊤ = { rows = [ 1, 2, 3 ], snapshot = [] }
pub update : Msg, Model → Model
update msg model =
    case msg of
        Capture → { model | snapshot = model.rows }
        Reverse → { model | rows = List.reverse model.rows }
number : List Int → Int
number rows = List.foldl rows 0 (λn total → total * 10 + n)
pub view : Model → Html Msg
view model = <section data-shape="adversarial"><button id="capture" onClick={Capture}>Capture</button><button id="reverse" onClick={Reverse}>Reverse</button><output id="rowsOutput">{number model.rows}</output><output id="snapshotOutput">{number model.snapshot}</output></section>
`,
 'event-capture':`import Html exposing (Html)

pub type alias Model =
    count : Int
    saved : Int
pub type Msg = Increment | Save Int
pub init : ⊤ → Model
init ⊤ = { count = 0, saved = 99 }
pub update : Msg, Model → Model
update msg model =
    case msg of
        Increment → { model | count = model.count + 1 }
        Save value → { model | saved = value }
pub view : Model → Html Msg
view model = <section data-shape="adversarial"><button id="increment" onClick={Increment}>Increment</button><button id="save" onClick={Save model.count}>Save</button><output id="countOutput">{model.count}</output><output id="savedOutput">{model.saved}</output></section>
`,
 'higher-order-capture':`import Html exposing (Html)

pub type alias Model =
    count : Int
    saved : Int
pub type Msg = Increment | Save Int
pub init : ⊤ → Model
init ⊤ = { count = 0, saved = 99 }
pub update : Msg, Model → Model
update msg model =
    case msg of
        Increment → { model | count = model.count + 1 }
        Save value → { model | saved = value }
child : (⊤ → Int) → Html Msg
child read = <div><output id="countOutput">{read ⊤}</output><button id="save" onClick={Save (read ⊤)}>Save</button></div>
pub view : Model → Html Msg
view model = <section data-shape="adversarial"><button id="increment" onClick={Increment}>Increment</button>{child (λ⊤ → model.count)}<output id="savedOutput">{model.saved}</output></section>
`,
 'pattern-helper-capture':`import Html exposing (Html)

type Box = Box Int
pub type alias Model =
    box : Box
    saved : Int
pub type Msg = Increment | Save Int
pub init : ⊤ → Model
init ⊤ = { box = Box 0, saved = 99 }
pub update : Msg, Model → Model
update msg model =
    case msg of
        Increment → { model | box = case model.box of
            Box value → Box (value + 1)
          }
        Save value → { model | saved = value }
child : Box → Html Msg
child box =
    case box of
        Box value → <div><button id="save" onClick={Save value}>Save</button><output id="countOutput">{value}</output></div>
pub view : Model → Html Msg
view model = <section data-shape="adversarial"><button id="increment" onClick={Increment}>Increment</button>{child model.box}<output id="savedOutput">{model.saved}</output></section>
`
};
for(const [suffix,source] of Object.entries(sources)){const name='adversarial-'+suffix,root=writeApp(base,name);fs.writeFileSync(root+'/Shape0.beni',source);const dir=import.meta.dirname+'/fixtures/'+name;fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(dir+'/Main.beni.txt',base.source);fs.writeFileSync(dir+'/Shape0.beni.txt',source);cases.push({name,n:1,seed:17,shape:'adversarial'})}
fs.writeFileSync(import.meta.dirname+'/.out/adversarial-cases.json',JSON.stringify(cases,null,2)+'\n');
