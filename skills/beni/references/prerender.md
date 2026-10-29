# Prerendered pages

On `browser-inline`, `Browser.prerender` writes one HTML page per route. Each page holds the
program's first render for its route. A static host serves the pages as files. When the page
loads, the program takes it over: it does not render the page again.

```beni platform=browser-inline
import Browser
import Browser.Navigation as Navigation
import Cmd exposing (Cmd)
import Html exposing (Html)
import Sub
import Tea
import Url exposing (Url)
import Url.Parser exposing (Parser, map, oneOf, s, slash, string, top)


type alias Post =
    slug : String
    title : String


posts : List Post
posts = [ { slug = "hello", title = "Hello" }, { slug = "second", title = "Second" } ]


type Route
    = Home
    | Article String
    | NotFound


route : Parser (Route → a) a
route = oneOf [ map top Home, s "blog" ▷ slash string ▷ map Article ]


toRoute : Url → Route
toRoute url = Maybe.withDefault (Url.Parser.parse route url) NotFound


type Msg
    = ClickedLink Browser.UrlRequest
    | UrlChanged Url
    | Refused Navigation.Error


type alias Model =
    key : Navigation.Key
    route : Route


update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        ClickedLink (Browser.Internal url) →
            ( model, Navigation.pushUrl model.key (Url.toString url) Refused )

        ClickedLink (Browser.External href) →
            ( model, Navigation.load href Refused )

        UrlChanged url →
            ( { model | route = toRoute url }, Cmd.none )

        Refused _ →
            ( model, Cmd.none )


title : Route → String
title r =
    case r of
        Home →
            "Home"

        Article slug →
            "Post ${slug}"

        NotFound →
            "Not found"


view : Model → Tea.Document Msg
view model =
    { title = title model.route
    , body =
        <main>
            <a href="/blog/hello">hello</a>
            <h1>{title model.route}</h1>
        </main>
    }


main : Tea.Program
main =
    Browser.prerender
        (Tea.application
            { init = λurl key → ( { key = key, route = toRoute url }, Cmd.none )
            , update = update
            , view = view
            , subscriptions = λ_ → Sub.none
            , onUrlRequest = ClickedLink
            , onUrlChange = UrlChanged
            }
        )
        ([ "/" ] ++ List.map posts λpost → "/blog/${post.slug}")
```

## When a program prerenders

- A program prerenders when `main` says `Browser.prerender program routes`. Write it in `main`,
  around the program or around a `Browser.mountAt`, or inside one. Anywhere else it is refused
  (`program_shape`), and so is `Browser.prerender` used as a value.
- `build`, `build --watch` and `serve` all prerender. `serve` prerenders after each build.
- `"build"."base"` must begin with `/`. The build runs the pages under the `node` on `PATH`. With no `node` there, the build fails
  (`prerender_needs_node`).
- On `browser-tea`, `Browser.prerender` gives the program back and reads no route. The same source
  builds there, rendered in the browser.

## Routes and files

| Route | File under `out/` | Served at |
|---|---|---|
| `/` | `index.html` | `/` |
| `/about` | `about.html` | `/about` |
| `/blog/hello` | `blog/hello.html` | `/blog/hello` |
| `/blog/` | `blog/index.html` | `/blog/` |

- A route begins with `/`. Its segments are not empty (but for the last one of a route that ends in
  `/`), not `.` and not `..`. They hold only ASCII letters, digits, `-`, `.`, `_` and `~`. The first
  segment does not begin with `_`. Another route is `invalid_route`.
- Two routes that write one file, also when only the case differs (`/About`, `/about`), are
  `output_path_collision`.
- When the list does not hold `/`, `index.html` is the shell with no view. The program mounts there
  as on any page.
- Configure the host to answer `/about` with `about.html`. GitHub Pages, Netlify and Cloudflare
  Pages do. `beni serve` does.

## What must be pure

`init`, `view` and the route list must be pure: the build computes each page, and the browser
computes the same first render again. A call that may read the clock, randomness or the host is
`prerender_impure`, at the call. `Debug.log` is allowed, also in another module. A render that
throws fails the build (`prerender_failed`), with the route.
- The build reads all the code that they can run, in each module of the program and its
  platforms. `init` can name a function of another module: `init = Counter.init`.
- A constant is computed when its module loads. A read of a constant whose code may be impure
  (`seed = Clock.now ⊤`) is `prerender_impure`, also in a called function or a lambda.
- A function with no parameters whose body is not a lambda (`stamp = Clock.now`) has no body that
  a call runs: write the parameter (`start ⊤ = initial ⊤`), or a call of it can be refused.
- A method call or an operator that may be impure is `prerender_impure`.

## What `init` gets

- `Tea.sandbox`, `Tea.element` and `Tea.document`: `init ⊤`, the same on every page.
- `Tea.application`: the `Url` of the page's route, never the address in the browser. Its
  protocol, host and port come from `"build"."origin"` in `beni.json`; its path is the base and the
  route; it has no query and no fragment. With no origin, the build fails
  (`prerender_needs_origin`).
- After the first render, the address the page was opened at goes to `onUrlChange`, when it differs
  from the route's `Url`. Read the query and the fragment there.
- An address that is the page's file name (`/about.html`, `/blog/index.html`) is replaced by the
  route. The query and the fragment stay.
- A page with no prerendered view gives `init` the address, as on `browser-tea`.

```json
{
  "build": { "platform": "browser-inline", "paths": ["src"], "origin": "https://example.com" },
  "html": "shell.html"
}
```

## The page shell

The shell needs `{{view}}` exactly once, in the element the program mounts at, as its last content:
`<body>{{view}}</body>`, or `<div id="root">{{view}}</div>` with `Browser.mountAt`. None, or two,
is `invalid_html_shell`. `{{title}}` is the page's title, escaped for a text or an attribute, from a `document`'s or an
`application`'s `view`: write `<title>{{title}}</title>`. A build that does not prerender writes
both as nothing.

## Input before the program runs

The page shows its view before its JavaScript runs, so a user can click, type or check a box
early. When the program listens to an event on an element of its view, the build writes a small
inline script before the view. The script records each such event. After the takeover, the
program gets each event in order, once, as a message to `update`. The control's value, `checked`
and selected option are the ones the user left. The browser does not run a default action again.

- A page whose program listens to no event gets no script.
- Pointer events (`Html.onPointerDown` and the others) are not recorded. Their position is read
  while the event is dispatched. The `click` of a tap is recorded.
- An event that no listener hears changes nothing. A control keeps the text the user typed after
  an event.
- When the page differs from the program (below), the recorded events are dropped.
- A content security policy that refuses inline scripts stops the script. Then the early input is
  lost, and nothing else changes.
- A link click or a form submit before the takeover loads a page, as on any page whose script has
  not run.

## The page differs from the program

When the HTML is not what the program makes (a browser extension or a CDN changed it), the program
mounts fresh in the same task. A development build writes a warning first.

## Build-time data

A site whose pages show files (blog posts) is two programs over a shared schema module. A data
program, built for `node`, reads the files once when the site is built. It gives each route and
its value. The site, built for `browser-inline`, makes each page from its value.

```text
beni.json
shell.html
src/Main.beni        the site
data/Main.beni       the data program
shared/Blog.beni     the schema that both programs compile
posts/hello.txt      what the data program reads
```

```json
{
  "build": {
    "platform": "browser-inline",
    "paths": ["src", "shared"],
    "data": { "paths": ["data", "shared"], "inputs": ["posts"] }
  },
  "html": "shell.html"
}
```

`shared/Blog.beni`:

```text
pub schema Page tagged "page" of
    Home as "home"
        titles : List String
    Article as "article"
        slug : String
        body : String
```

The data program, `data/Main.beni`. Its `main` is `Prerender.pages schema body`. `body` runs once
in a fiber, so it may read files and wait. It runs with its working directory at the project root.

```text
import Blog exposing (Page)
import Io
import Node exposing (Program)
import Prerender


main : Program
main = Prerender.pages (Page.schema ⊤) λ⊤ →
    case Io.readFile "posts/hello.txt" of
        Ok body →
            Ok [ ( "/", Page.Home { titles = [ "hello" ] } ), ( "/blog/hello", Page.Article { slug = "hello", body = body } ) ]

        Err _ →
            Err "cannot read posts/hello.txt"
```

The site's `main` is `Browser.prerenderData schema λvalue → program`:

```text
main : Tea.Program
main = Browser.prerenderData (Page.schema ⊤) λpage →
    Tea.document
        { init = λ⊤ → ( { page = page }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = λ_ → Sub.none
        }
```

- The routes are the data program's. The site lists none. The route rules above apply
  (`invalid_route`). `index.html` is the page of `/`, or is not written.
- Each page holds its own value, encoded by the schema, in a `<script type="application/json">`.
  The build renders the page from the value it decodes from that text, and the page decodes the
  same text before `init`. A page carries only its own value.
- Only `init` may read the value: put it in the model. A read in `view`, `update` or
  `subscriptions` is `program_shape`. The lambda's parameter is a name or `_`.
- The schema must be a `schema` declaration's `X.schema ⊤`, `Schema.derived ⊤`, a primitive, or
  those composed by `Schema.list`, `Schema.nullable` or `Schema.converted`. A schema that the
  library's builders make is `program_shape`. A conversion that may be impure is
  `prerender_impure`.
- An `Err` from `body`, a throw, a value that the schema cannot encode, or a data `main` that is not
  `Prerender.pages`, is `prerender_data_failed`. A text that the site's schema cannot decode is
  `prerender_data_invalid`.
- A site that says `Browser.prerenderData` and has no `"build"."data"` is `prerender_needs_data`.
  A `"data"` with any other `main` is the warning `prerender_data_ignored`.
- `Debug.log` is allowed in the data program, also with `--release`: the data program is always a
  development build, and it does not ship.
- `build --watch` and `serve` run the data program again when a file under its `"paths"` or its
  `"inputs"` changes.
- A page whose script was changed so that it does not decode, or was taken out, stops when it
  loads.
- Built alone (`beni build --platform=node --out=data-out data shared`) and run with no argument,
  the data program writes its records to standard output.

Sources: `docs/design/prerender.md` §3, §5, §6, §6.5, §7, §8, §9; `docs/design/frontend.md` §10.1,
§10.3, §10.4.
