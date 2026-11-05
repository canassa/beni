# Routing: documents, applications and the address

`Tea.document`, `Tea.application` and `Browser.Navigation` are on `browser-tea` and on
`browser-inline`, with the same signatures. One source builds on both.

- `Tea.document`: `view` gives `{ title, body }`. The page's title follows the model.
- `Tea.application`: a `document` that owns the address. `init` gets the page's `Url` and
  `Navigation.Key`. A click on a link of the page goes to `onUrlRequest` as `Browser.Internal url`
  or `Browser.External href`. Each change of the address goes to `onUrlChange`. A page opened from a
  file stops at start: it has no `http` or `https` address.
- A link whose own `onClick` handler calls `Html.preventDefault event` is not a request:
  `onUrlRequest` gets nothing for it, and its handler's message goes to `update`. Use this to keep
  one link out of routing.
- `Browser.Navigation`: the commands `pushUrl`, `replaceUrl`, `back`, `forward`, `load` and `reload`.
  The last argument of each is the message for a refusal (`BadUrl`, `CrossOrigin`, `Throttled`).
  The direct forms are `push`, `replace`, `goBack`, `goForward`, `loadPage` and `reloadPage`.
  `currentUrl ⊤` is the address, or `Nothing` for a file. A push is sent to every `onUrlChange`.
- `Url.Parser` and `Url.Builder` are core modules.

```beni platform=browser-inline
import Browser
import Browser.Navigation as Navigation
import Cmd exposing (Cmd)
import Html exposing (Html)
import Sub
import Tea
import Url exposing (Url)


type Msg
    = ClickedLink Browser.UrlRequest
    | UrlChanged Url
    | Refused Navigation.Error


type alias Model =
    key : Navigation.Key
    path : String


update : Msg, Model → Model × Cmd Msg
update msg model =
    case msg of
        ClickedLink (Browser.Internal url) →
            ( model, Navigation.pushUrl model.key (Url.toString url) Refused )

        ClickedLink (Browser.External href) →
            ( model, Navigation.load href Refused )

        UrlChanged url →
            ( { model | path = url.path }, Cmd.none )

        Refused _ →
            ( model, Cmd.none )


view : Model → Tea.Document Msg
view model =
    { title = model.path
    , body =
        <main>
            <a href="/about">about</a>
            <h1>{model.path}</h1>
        </main>
    }


main : Tea.Program
main =
    Tea.application
        { init = λurl key → ( { key = key, path = url.path }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = λ_ → Sub.none
        , onUrlRequest = ClickedLink
        , onUrlChange = UrlChanged
        }
```

## On `browser-inline`

- Write the `{ title, body }` record in the `view` itself.
- A refusal message must not wait: give a constructor, as above.
- There is no `eachUrlRequest` or `eachUrlChange`. They need a fiber.
- A link's `href` can change: `href={"/blog/" ++ slug}`. A `javascript:` or `data:text/html` URL is
  written as an empty `href`, as on `browser-tea`. The build checks a literal. The page checks a
  value when it writes it.
- `Browser.prerender` writes a page per route. A prerendered `application`'s `init` gets the route,
  not the address; the address comes to `onUrlChange` (`prerender.md`).

Sources: `docs/design/boundary.md` §9.8.13, §9.8.17; `docs/design/browser-inline.md` §10.
