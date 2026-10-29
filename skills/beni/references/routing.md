# Routing: documents, applications and the address

`Tea.document`, `Tea.application` and `Browser.Navigation` are on `browser-tea` and on
`browser-inline`, with the same signatures. One source builds on both.

- `Tea.document`: `view` gives `{ title, body }`. The page's title follows the model.
- `Tea.application`: a `document` that owns the address. `init` gets the page's `Url` and
  `Navigation.Key`. A click on a link of the page goes to `onUrlRequest` as `Browser.Internal url`
  or `Browser.External href`. Each change of the address goes to `onUrlChange`. A page opened from a
  file stops at start: it has no `http` or `https` address.
- `Browser.Navigation`: the commands `pushUrl`, `replaceUrl`, `back`, `forward`, `load` and `reload`.
  The last argument of each is the message for a refusal (`BadUrl`, `CrossOrigin`, `Throttled`).
  The direct forms are `push`, `replace`, `goBack`, `goForward`, `loadPage` and `reloadPage`.
  `currentUrl ⊤` is the address, or `Nothing` for a file. A push is sent to every `onUrlChange`.
- `Url.Parser` and `Url.Builder` are core modules.
- `Url.fromString` parses an `http` or `https` URL as a browser does. It does not use the host's
  `URL`, so it also runs where no `URL` exists. A host in Unicode (`bücher.de`) gives `Nothing`.
  Write the host in its ASCII form (`xn--bcher-kva.de`). The address of a page is always in that
  form.

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
- A link's `href` must be a literal. A `javascript:` URL is written as an empty `href`.

Sources: `docs/design/boundary.md` §9.8.13 (a) and its amendments, §9.8.17; `docs/design/browser-inline.md` §10.
