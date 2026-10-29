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
`prerender_impure`, at the call. `Debug.log` is allowed. A render that throws fails the build
(`prerender_failed`), with the route.

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

## The page differs from the program

When the HTML is not what the program makes (a browser extension or a CDN changed it), the program
mounts fresh in the same task. A development build writes a warning first.

Sources: `docs/design/prerender.md` §3, §5, §6, §7, §9; `docs/design/frontend.md` §10.1, §10.4.
