# The browser platform — the plan

**Status:** plan **revision 2**, 2026-09-20. **Implementation is parked.** Nothing here is started
and nothing here is normative: the normative documents are `language.md`, `frontend.md`,
`checker.md`, `backend.md`, `boundary.md` and
[`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md) (**P2**), and §4
lists the edits this plan would owe them *once the owner answers*
[`plans/browser-decisions.md`](browser-decisions.md).

**What changed in revision 2.** The owner read revision 1 and asked for built-in JSX and for a UI as
fast as Solid. Three reports answered, and the plan changes in three places. The **virtual DOM is
gone** from §2 — it is replaced by a compiled-template renderer, on measured grounds. Two **new
tracks** appear in §3, a language track for JSX and a rendering track for templates, and the most
useful fact in this document is that **almost none of either needs anything from the effects spike**.
And one question is **not answered** and is named as such: what an `Html msg` value is at run time
(W29), with a prototype experiment (**X1**) that settles it.

**Revision 3, 2026-09-29 — read this block first.** The owner answered W25–W34, the *JSX
compiler*, *JSX targets* and *Layers* rows, and research 36's seven questions
([`browser-decisions.md`](browser-decisions.md), *Answered by the owner*), and the markup
specification is written: [`language.md`](../docs/design/language.md) §11,
[`frontend.md`](../docs/design/frontend.md) §9, [`checker-v2.md`](../docs/design/checker-v2.md) §25,
[`boundary.md`](../docs/design/boundary.md) §9 and [`backend.md`](../docs/design/backend.md) §15.
Those documents are normative; where this plan's revision-2 text below disagrees with them, they win,
and the items they overturn are marked **SUPERSEDED** in place and listed in the table below. The new
slice plan is **§7**.

**Revision 3.1, 2026-09-29 — after the specification review.** The owner answered the review
([`browser-decisions.md`](browser-decisions.md), *Spec review answers*): text follows Solid 2 exactly,
keyed `Show` stays, `class` and `style` get typed forms, and the lowering interface is stable under
additive change. The five sections were revised in place with the review's findings fixed. **The
ids in this plan are renamed** so they collide with nothing: the specification's decisions are
**MD1…** (they were D1–D23, which `checker-v2.md` §21 and `plans/m4-plan.md` also use) and the markup
slices **MJ0…** (they were J0–J9, which research 28 §12 and research 36 §7 use for their own lists,
and those reports keep theirs).

### Decisions this spec took

The owner's answers leave these open; the specification chose, and each is the owner's to overturn.
**Status** says whether the owner's answers have since settled it; *new* marks a decision the review
revision had to take.

| # | Decision | Why | Where | Status |
|---|---|---|---|---|
| MD1 | **A capitalised tag names a module and the component is its `view`**; `<Card.header />` is that module's `header` | JSX's "a capital names a value" is impossible — a capitalised expression is a constructor — and a lower-case tag is an element (W31); the member form is Solid's member-expression rule and removes "one component per module" | `language.md` §11.8 | open |
| MD2 | **Props are a closed record; optional props are a leading spread**, `<Card {...Card.defaults} title="x" />` = record update; a spread elsewhere is refused | no new language feature; a later spread would only override props the closed type already has | §11.8 | open |
| MD3 | **`children`**: nothing → absent; one hole → that value (render functions work); otherwise one fragment. **Children are evaluated eagerly** — forced by strict evaluation, not chosen; a component wanting laziness takes a function | Solid's single-or-array rule, typed; Solid's lazy `get children()` has no counterpart in a strict language | §11.8 | open |
| MD4 | **`For` uses Solid 2's actual spelling, one `keyed` attribute** (`keyed={f}`, `{False}`, `{True}`), not question 4's `key=`; absent means by reference, warned (`unkeyed_for`) unless the item type is primitive-`eq`; a key must be a primitive-`eq` type; duplicate keys render by (key, rank); `fallback`; the row function may take its position. **Absent `keyed` over a primitive-`eq` item type is not a silent default, and so is consistent with research 36 question 4's "no silent default"**: identity on a `String` or `Int` is equality, so by reference there is by value, exactly what `keyed={\x -> x}` would say — there is no second mode for silence to hide | Solid 2 is the reference; identity on a record key would be a silent wrong answer; a dropped duplicate would be too | §11.9, `backend.md` §15.5 | open |
| MD5 | **Keyed `Show` is kept; non-keyed `Show`, `Switch` and `Match` are not provided** (`if`/`case` are expressions) | the owner's answer | §11.6, §11.18 | **settled by the owner** (spec review), replacing "no `Show`" |
| MD6 | **A `List (Html msg)` hole is positional and never warned** (W33's warning is not carried to it) | it is the explicit spelling of positions, and `For` is where keys live | §11.6 | open |
| MD7 | ~~Whitespace is the space and the newline only~~ | — | — | **withdrawn by the owner**: text collapses all Unicode whitespace, as Solid's `trim_jsx_text` does (§11.4) |
| MD8 | ~~Text is literal: no HTML character references, and `html_entity_in_text`~~ | — | — | **withdrawn by the owner**: references are decoded exactly as Solid decodes them, and the warning is gone (§11.4). `>`, `}` and a stray `<` in text stay refused |
| MD9 | **An attribute string is a beni string** (escapes, `${…}`); a quoted attribute name is the untyped escape | one string syntax; `class="btn ${size}"` | §11.5 | open, amended by MD25 |
| MD10 | **Spread on an element is deferred** (`spread_on_element`), and with it **a tag chosen at run time** (`Html.node`, Solid's `<Dynamic>`) | it moves every attribute of the element to run time (research 27 §6.11 D); a spread of known fields needs its own design, and so do untypable attributes | §11.5, §11.13 | open |
| MD11 | **A handler's form is decided by its type**; a variable at generalisation is a message | static and deterministic; the one corner, a function-valued message, is written as a lambda | §11.7, `checker-v2.md` §25.4 | open |
| MD12 | **Until effects land, `preventDefault`/`stopPropagation` are facts of an event's declaration** | W34's "the handler calls it itself" needs effectful handlers | §11.7, §11.14 | open |
| MD13 | **Vocabulary declarations name their markup name with a string**, carry facts as contextual words, allow one `*` (`"data-*"`, `"aria-*"`, `"*-*"` for custom elements), scope attributes with `on`, admit five value types, and take a payload extractor with `via` (an ordinary `foreign`); `url` makes a lowering sanitise script URLs (Elm's rule) and `raw` is the warned `innerHTML` escape; `classes` and `styles` admit the lists of MD27 | a markup name is not an identifier; `pub element "x"` is unambiguous with two tokens of lookahead | §11.14, `boundary.md` §9.3 | open |
| MD14 | **`void` is both a vocabulary typing fact and a parser-table fact**; a disagreement is `markup_restructured` | question 2 put the parser's rules in the lowering; the checker still needs to refuse children | §11.5, `backend.md` §15.3 | open |
| MD15 | **Markup needs no import**: the graph adds the platform's vocabulary module as an import of every module that writes markup, never of the vocabulary module itself; the markup type is named by the manifest | Solid's intrinsic elements need none either, and the per-file `Bir` cannot name the platform | `frontend.md` §9.8, `boundary.md` §9.2 | open |
| MD16 | **Layering**: manifest keys `"platforms"` and `"reexports"`; a dependency's output under `_platform/_<name>/`; `program`/`runtime`/`entry` and each `markup` field inherited first-found; built-in platforms `html`, `browser`, `browser-tea`, `node`; **TEA is beni over `browser`'s `Program`** with no runtime of its own | siblings may not import files, so layers share beni, not JavaScript | `boundary.md` §9.1 | open |
| MD17 | **The lowering interface**: the compiler evaluates every value and hands the lowering handles, never expressions; the lowering runs in `build` only, through a builder that can name no host global; two callbacks (`module`, `root`) plus `rowValues`; one diagnostic, `markup_restructured`; external platforms by `-Dplatform=<dir>` or `beni.addPlatform`; a platform's Zig may import the Zig of platforms it depends on | evaluation order and the wall stay the compiler's, not every lowering's | `boundary.md` §9.4–§9.5 | open; versioning settled, MD32 |
| MD18 | **Only `For` rows are compiled away in interface version 1.0**; components, helpers, branches, `Show` bodies and `view`'s root are blocks. Research 36 also listed component calls and inline `if`s as direct consumers | blocks were measured ahead of Solid 2; MJ9's helper-heavy page decides whether more pay | `backend.md` §15.4–§15.5 | open |
| MD19 | **Delegated events are registered by the entry file's call of the runtime's `start`**, whose data is one object of sorted keys to sorted string arrays; a `--library` build registers per kind through `delegate` | loading a module must do nothing (`backend.md` §9) | `boundary.md` §9.4.5, `backend.md` §15.1, §15.3 | open |
| MD20 | **The checker's markup facts ride in the dispatch table** (`dispatch_bytes` 4 → 5, `entry_bytes` 4 → 5); vocabularies in the interface (`iface_bytes` 7 → 8); the front-end artifact 4 → 5 | one sidecar, one round-trip flag | `checker-v2.md` §25.7–§25.8 | open |
| MD21 | **The plain-call form is the component equivalence**, exactly; run-time constructors are markup primitives (MD28), never recognised by the compiler; research 28's rule 19 is withdrawn | W32: JSX is the template compiler | `language.md` §11.13 | open |
| MD22 | **A component, a row or a `Show` body may be skipped** when its inputs are identical, so a render evaluates it zero or one times; never once effects make it `impure` | `lazy`'s job, done by the compiler at boundaries the program drew | §11.8, §11.11 | open |
| MD23 | **The formatter writes `<div />`** (a space, JSX's formatters' spelling), normalises `<div></div>` to it (W41), and never changes a whitespace gap's newline or emptiness | canonical, and cannot change the page | §11.15 | open |
| MD24 | *New.* **The character-reference table is the compiler's**, generated from WHATWG's `entities.json`, and text is decoded in BIR lowering after trimming — Solid's order, so a typed no-break space collapses and `&nbsp;` survives; every lowering receives decoded text, and `dom` re-encodes it for its template | decoding is JSX's text syntax, not vocabulary; in a platform, what a page says would depend on the lowering and every lowering would carry 2 231 names | `language.md` §11.4, `frontend.md` §9.7 | for the owner |
| MD25 | *New.* **A quoted attribute value, and a quoted component prop, decode references in their literal text** — Solid decodes every JSX attribute string (`shared/attr_plan.rs:374`) and string prop (`shared/component.rs:87`); a character an escape writes never begins a reference, an interpolation's value and a `{"…"}` hole are never decoded | the owner takes Solid 2's answer by default, and nothing in beni forces a departure | `language.md` §11.5 | for the owner |
| MD26 | *New.* **`Show`'s shape**: `when : Maybe a` (beni has no truthiness), `keyed` required, the body one function hole `a -> Html msg`, `fallback` optional; **`keyed={f}` keys by a primitive key**, beni's addition, because by identity remounts on every edit of the shown record in an immutable language — `For`'s hazard; `keyed={False}` and a missing `keyed` are refused with the `case` spelling | Solid 2's keyed `Show` (`flow.ts:164-241`), typed | `language.md` §11.18 | for the owner |
| MD27 | *New.* **`class` and `style` keep their names and take typed lists**: `List ( String, Bool )` and `List ( String, String )`, declared by the facts `classes` and `styles`; a list literal of pairs is split at compile time into template constants and guarded toggles, any other list goes through ports of Solid's `className`/`style` diffs. **Lists, not records**: class names and CSS properties are not field names, and "a record of `Bool`s" is not a beni type. An empty style value removes the property; a class listed twice is present if any entry is `True` | Solid 2 merged `classList` into `class` and rejected two names (`07-dom.md:158`); `List ( String, Bool )` is Elm's `classList` | `language.md` §11.19, `backend.md` §15.3, §15.6 | for the owner |
| MD28 | *New.* **Markup primitives**: `pub markup name : T` in the vocabulary binds to the build's markup runtime, so `Html.text` and `Html.map` serve every lowering; a `foreign` whose type mentions the markup type is legal only in a platform that names the build's lowering (`markup_type_in_foreign`) | one sibling cannot build two lowerings' representations; this is the per-lowering runtime export the review asked for | `language.md` §11.13–§11.14, `boundary.md` §9.3 | for the owner |
| MD29 | *New.* **`Html.map` is Elm's**, implemented in `dom` by a mount context chain: each event node inside a map points at its context, a map's `p` updates its function in place, the listener applies the chain innermost first; `ssr`'s `map` is the identity | TEA with a nested `Msg` needs it; free outside maps, one property write per event node inside | `language.md` §11.13, `backend.md` §15.3 | for the owner |
| MD30 | *New.* **`browser`'s program runtime and markup runtime are one file**, so a delegated listener can reach `send`; its `Program` is data `run` interprets, mounted at `document.body` until W9 says what `main` is | a sibling may not import another file | `boundary.md` §9.2, `backend.md` §15.11 | for the owner |
| MD31 | *New.* **The row function is any function**; a row is skipped on its item, position and **inputs** — the field paths its body reads from each captured local, through calls to the same module's functions by summary, else the whole local — so `rowClass model row` skips on `model.selected`. No warning when a row captures a whole record the analysis cannot see into; `--self-profile` counts them. *The owner may prefer a warning* (`row_reads_whole_record`, at the capture, naming the field to pass instead): it would be a rule-7 warning, never an error | rule 8: an unchanged row must cost a pointer comparison for the idiomatic shape, research 29 §7.2's field dependencies | `language.md` §11.9, `frontend.md` §9.7, `backend.md` §15.5 | for the owner |
| MD32 | *New, the owner's principle applied.* **Interface versioning `{ major, minor }`**: every enumeration non-exhaustive and read through accessors, so an addition never breaks an old lowering's compile; a feature a lowering must render is gated by `Tree.requires` against `Lowering.targets`, refused as `markup_feature_unsupported` rather than rendered wrong; only a breaking change moves the major, found at `comptime` | "stable under additive change" (spec review answers) | `boundary.md` §9.4.6 | settled in principle; mechanism for the owner |
| MD33 | *New.* **The `html` layer is kept** under `browser` and `node`, holding the vocabulary, the markup type, the primitives and the parser table | a view module must check against one `Html` type to build under both lowerings; the alternative, a vocabulary per platform, gives two unrelated types | `boundary.md` §9.1 | **for the owner** |
| MD34 | *New.* **The `markup` key is inherited field by field**: `html` declares `vocabulary` and `type`, `browser` and `node` `lowering` and `runtime` (from one package); `check --platform=html` works, `build --platform=html` without `--library` is refused as having no `program` | the review's gaps in how a program-less, lowering-less platform behaves | `boundary.md` §9.1–§9.2 | for the owner |
| MD35 | *New.* **The built-in forms' own attributes are validated** (`unknown_form_attribute`, `missing_form_attribute`), and three codes are renamed for `Show` (`invalid_form_children`, `invalid_keyed`, `key_not_primitive`) | a misspelt `keyed` must not silently key by reference | `language.md` §10, §11.9 | for the owner |
| MD36 | *New.* **The render loop (W28) as a contract**: one microtask flush per batch, patch then after-render work, no layout reads in the patch, the runtime's `flush` drains now; `Browser.flush` and after-render capabilities are values `run` interprets and arrive with effects. **Controlled inputs need no synchronous render**, since a microtask flush reconciles before the next input event | W28's answer, with the pieces effects owe named so no phase is missing | `backend.md` §15.11 | settled by W28; the pre-effects position for the owner |
| MD37 | *New.* **Portals and `ref` are out of scope** for now | portals wait on the mount and after-render design; `ref` on question 6 | `language.md` §11.16 | for the owner |
| MD38 | **Decided by the owner, 2026-09-29: refused.** **The untyped escape can write an event-handler attribute**: `"onclick"={userText}` is a script sink, which Elm closes by refusing `on*` attribute names (research 24 §6.3, `VirtualDom.js:274-333`). The spec leaves the escape unrestricted; closing it would be a guarantee (no script injection from view data), so it would be an error with the typed event as the escape | the one hole beside `raw` a `view` could inject script through | `language.md` §11.5 | **owner: refuse** — a quoted attribute name beginning with `on` (any case) is a compile error pointing to the typed event attributes |
| MD39 | **Decided by the owner, 2026-09-29: the other script sinks are closed too.** (1) A quoted attribute name may contain only valid attribute-name characters — no whitespace, quotes, `=`, `/`, `>` or control characters; (2) a quoted `href`, `src`, `action`, `formaction` or `xlink:href` gets the typed attribute's `javascript:`-URL sanitising; (3) `srcdoc` is refused through the escape; (4) `script` is removed from the `html` vocabulary (pages load scripts through the platform, not through `view`) | a `view` must not be able to run injected script, by the escape or the vocabulary (Elm's rules, research 24 §6.3) | `language.md` §11.5, §11.14; the `html` platform | **owner: close all four** — built 2026-09-29: `invalid_attribute_name`, the markup section's `url` escapes, `untyped_srcdoc_attribute`, and no `script` in `html` |

### What the decisions overturned

| Item below | Status | Replaced by |
|---|---|---|
| §1.1's `view` (quoted text, `Html.keyed`) and its "plain-call form of one branch" | **SUPERSEDED** | bare text and `For`: `language.md` §11.4, §11.9; the plain-call form is §11.13 |
| §2.2's rows *template extraction* (`backend.md` §11), *fallback tree path*, *element vocabulary* (W37) | **SUPERSEDED** | `backend.md` §15; blocks, §15.4; vocabulary declarations, `language.md` §11.14 |
| §2.3's seam (desugar to calls, a `--release` recogniser), `Keyed msg`, the handler variant as data | **SUPERSEDED** | templates by construction, never `--release`-gated (W32); `For` (W33); event facts (MD12) |
| §2.3's *fallback path* subsection (W29 open) | **ANSWERED** | blocks, `backend.md` §15.4 (question 3) |
| §2.4 items 1–2 (one render per frame; a render-now) | **SUPERSEDED** | W28: Solid 2's microtask flush and `flush()`, `backend.md` §15.11; items 3–4 are specified there too |
| §3's **L1** (quoted text, JSX as sugar) | **SUPERSEDED** | MJ1–MJ5 (§7) |
| §3's **L2** (typed holes over `Html.keyed`/`Keyed msg`) | **SUPERSEDED** | MJ4 (§7) |
| §3's **L3** (the identity promise) | **KEPT**, folded into MJ4–MJ5 | `language.md` §11.12, `backend.md` §15.8 |
| §3's **R1** (a `--release`-gated recogniser, `backend.md` §11) | **SUPERSEDED** | MJ6 and MJ9 (§7); its exit table survives as MJ9's bar |
| §3's **R2** (`Keyed msg`, `unkeyed_list_hole`) | **SUPERSEDED** | `For` and `unkeyed_for`, MJ7 |
| §3's **R3** (field analysis) | **KEPT**, rung 3 specified at the row | a row's inputs are the fields it reads (MD31, `language.md` §11.9); the model-level diff and the selector (rung 4) after MJ9, and after X3 |
| §3's **X1** (the fallback experiment) | **SUPERSEDED** | question 3 accepted blocks; MJ9's helper-heavy page measures them |
| §3's **B2′**, **B3** | **SUPERSEDED** | MJ6–MJ8 |
| W37 (well-known runtime names declared by a platform) | **SUPERSEDED** | a lowering's runtime exports, `boundary.md` §9.4.5 |
| §4's rows for `language.md`, `frontend.md`, `checker.md`, `backend.md` new §11, `boundary.md` new §9 | **DONE, differently** | the five sections named at the top of this block |
| §5 risk 1 (what an `Html msg` is) | **ANSWERED** | a block, `backend.md` §15.4; MJ9 measures it |
| §6's phases 1–2 (L1, R1, L2, R2, B2′, B3) | **SUPERSEDED** | §7's order |
| this block's own MD5, MD7, MD8 (revision 3) | **OVERTURNED** by the owner's spec review answers | keyed `Show` (MD5, MD26), Solid's whitespace and character references (MD24, MD25) |

**How to read it.** Every part is marked with the `W` ids it depends on, so the plan survives the
owner choosing differently. Evidence is **R24** … **R29** (`docs/design/research/24…29`); no number
appears without its source and its caveat. Three caveats run through every figure in §2 and §3 and
are not repeated at each one: **headless Chrome 153, one engine, one machine**; R29's prototypes are
**hand-written, not compiler output**; and **most benchmark operations are paint-bound**, so a script
ratio of 2× is 2–15 % end to end (R27 §10.4, R29 §5.5).

---

## 1. What a beni browser program is

*Depends on: **W25** (TEA, commands handed a `send`), **W26** (compiled templates), **W28** (the
render phases), **W6** (subscriptions), **W8** (`sync` handlers), **W9** (`main`), **W30**–**W34**
(the JSX surface). Under a different W25 this page is rewritten; under a different W30/W31 the markup
is respelled and nothing else moves, because JSX desugars to the plain-call form.*

This is the page that replaces P2 §6.6. It is R25 §2's running example — a search box that debounces,
cancels the stale request, and toggles a favourite optimistically — in its option-C form, with its
view in the recommended JSX surface, and its test beside it.

**Marking.** `[proposed]` marks anything that does not exist: the `Browser` package whole,
`Cmd`/`Send`, `Task.sleep`, `Ref`, the `sync` keyword (decided by A6, not built), and **all markup**.
Everything else is `language.md` as it stands today: calls are saturated, function types are n-ary,
`|>` is pipe-first, `where` sits on a top-level annotation, and at most one `_` appears per
application. **The markup is confined to `view` functions**, so the rest of the file parses today.

### 1.1 The program

```elm
--! `Typeahead` — a whole beni browser program. [proposed] throughout: the
--! `Browser` package, `Cmd`, `Send`, `Task`, `Duration`, the `sync` keyword,
--! and every element in `view`/`viewStatus`/`viewHit`. Five small helpers are
--! elided for space — `statusOf`, `setMember`, `errorText`, `boolText` and
--! `realApi` — all pure, all ordinary beni.
import Browser exposing (Sub)
import Browser.Cmd as Cmd exposing (Cmd, Send)
import Browser.Html as Html exposing (Html)
import Duration
import Set exposing (Set)
import Task


type alias HitId =
    String


type alias Hit =
    { id : HitId, title : String }


type HttpError
    = Timeout
    | NetworkError
    | BadStatus Int


--| The one service. A7 decided services are records of functions, so this is
--| the whole of this program's dependency injection: `search` and
--| `setFavourite` both PERFORM, so both are inferred `suspends`, and a test
--| passes a record of fakes where the platform passes the real one.
type alias Api =
    { search : String -> Result HttpError (List Hit)
    , setFavourite : HitId, Bool -> Result HttpError ()
    }


type Status
    = Idle
    | Loading
    | Failed HttpError
    | Loaded (List Hit)


--| Grouped rather than flat, deliberately. A `{ r | f = x }` is emitted as a
--| spread, and V8's fast object-clone path gives up above ~17 fields: 29.9 ns
--| at 17, 222.6 ns at 18 (R27 §5.6). It is also what the renderer wants — a
--| hole compares the record it READS FROM, never the root model, which always
--| changes. W39, and X1 is the measurement that confirms or overturns it.
type alias Search =
    { query : String, status : Status }


type alias Model =
    { search : Search
    , favourites : Set HitId
    , saving : Set HitId
    , width : Int
    }


type Msg
    = Typed String
    | GotHits (Result HttpError (List Hit))
    | Favourited HitId Bool
    | Saved HitId Bool (Result HttpError ())
    | Resized Int


--| Keys name work, not values. An ADT and not a `String`: a mistyped string
--| key silently never cancels, which is rule 7's silent-wrong-answer class,
--| and a derived `compare` on this type costs nothing.
type Key
    = SearchKey
    | FavouriteKey HitId


sync init : Api, () -> ( Model, Cmd Msg )
init _ _ =
    ( { search = { query = "", status = Idle }
      , favourites = Set.empty
      , saving = Set.empty
      , width = 0
      }
    , Cmd.none
    )


--| `language.md` §6.3: a record update's target is a plain NAME — `{ r.a | … }`
--| is not allowed — so a nested update binds the sub-record first. That is the
--| whole ergonomic cost of grouping, and it is one `let` line.
sync update : Api, Msg, Model -> ( Model, Cmd Msg )
update api msg model =
    case msg of
        Typed q ->
            let
                s = model.search
            in
            ( { model | search = { s | query = q, status = Loading } }
            , Cmd.performKeyed SearchKey Cmd.Restart (searchEffect api q _)
            )

        GotHits result ->
            let
                s = model.search
            in
            ( { model | search = { s | status = statusOf result } }, Cmd.none )

        Favourited id want ->
            ( { model
                | favourites = setMember model.favourites id want
                , saving = Set.insert model.saving id
              }
            , Cmd.performKeyed (FavouriteKey id) Cmd.Restart (saveEffect api id want _)
            )

        Saved id _ (Ok _) ->
            ( { model | saving = Set.remove model.saving id }, Cmd.none )

        Saved id want (Err _) ->
            ( { model
                | favourites = setMember model.favourites id (not want)
                , saving = Set.remove model.saving id
              }
            , Cmd.none
            )

        Resized w ->
            ( { model | width = w }, Cmd.none )


--| An effect is a fiber handed a `send`. `Task.sleep` is a call, so debounce
--| is a line; the next `Typed` returns a command under the same key with
--| `Restart`, the runtime interrupts this fiber wherever it is parked, its
--| finalisers run (the `fetch`'s `AbortController` fires), and the
--| continuation that would have called `send` no longer exists. The stale
--| response cannot land — not "is ignored": cannot land.
searchEffect : Api, String, Send Msg -> ()
searchEffect api q send =
    let
        () = Task.sleep (Duration.millis 250)
    in
    send (GotHits (api.search q))


saveEffect : Api, HitId, Bool, Send Msg -> ()
saveEffect api id want send =
    send (Saved id want (api.setFavourite id want))


--| Declared from the model and diffed after every message: the runtime starts
--| a scoped fiber for each key that arrived and closes the scope of each key
--| that left, so nobody writes `unsubscribe` and a listener cannot leak.
sync subscriptions : Model -> Sub Msg
subscriptions _ =
    Browser.onResize Resized


--| `view` is `sync` and pure. Every handler is `sync` too: it may call
--| `preventDefault`, and if it wants slow work it spawns a fiber and returns
--| (R26 §5.1 — one macrotask hop and the link has already navigated).
sync view : Model -> Html Msg
view model =
    <div class="typeahead" style={Html.style [ ( "max-width", "${model.width}px" ) ]}>
        <input
            class="query"
            value={model.search.query}
            placeholder="Search…"
            onInput={Typed}
        />
        {viewStatus model}
    </div>


sync viewStatus : Model -> Html Msg
viewStatus model =
    case model.search.status of
        Idle ->
            <p class="hint">"Start typing."</p>

        Loading ->
            <p class="hint" "aria-busy"="true">"Searching…"</p>

        Failed err ->
            <p class="error" role="alert">"Could not search: ${errorText err}"</p>

        Loaded [] ->
            <p class="hint">"No results for “${model.search.query}”."</p>

        Loaded hits ->
            <ul class="results">
                {Html.keyed (List.map hits (\hit -> ( hit.id, viewHit model hit )))}
            </ul>


sync viewHit : Model, Hit -> Html Msg
viewHit model hit =
    let
        isFav = Set.member model.favourites hit.id
        isSaving = Set.member model.saving hit.id
    in
    <li class="hit">
        <span class="title">{hit.title}</span>
        <button
            class="fav"
            disabled={isSaving}
            "aria-pressed"={boolText isFav}
            onClick={Favourited hit.id (not isFav)}
        >
            {if isFav then "★" else "☆"}
        </button>
    </li>


main : Program
main =
    Browser.element
        { init = \flags -> init realApi flags
        , update = \msg model -> update realApi msg model
        , view = view
        , subscriptions = subscriptions
        }
```

> **SUPERSEDED 2026-09-29 as markup**: text is bare, not quoted (W30), and `{Html.keyed …}` is `<For each={hits} keyed={.id}>{\hit -> viewHit model hit}</For>` (W33) — `language.md` §11.4, §11.9. The architecture around the view stands.

Six things to notice, because each is a rule earning its keep rather than a style choice.

- **`{hit.title}` is a `String` hole, and no `Html.text` wrapper is written.** The checker knows the
  type, so the compiler inserts the conversion and the update is `node.data = hit.title`. Lustre's
  own React-migration guide names that wrapper as the cost of the plain-call form; this is the
  clearest thing JSX buys beni that `Html.div [] []` cannot (R28 §4.4).
- **`{if isFav then "★" else "☆"}` is also a `String` hole** — an ordinary `if` expression, no
  `<Show>`. And `viewStatus`'s five branches are five templates with the hole swapping between
  them, which is the shape `src/js/Decision.zig` already produces for a `case` (R28 §4.5).
- **`"aria-pressed"={…}` is the quoted-name escape** from the typed vocabulary: no hyphen join in the
  parser, no `attr:` namespace, and the reader can see at a glance that it left the typed set. It is
  stolen from Dioxus and Sycamore (R28 §5.2).
- **`Html.keyed` makes the list hole a `Keyed msg`**, a *different type* from `List (Html msg)`, so
  the keyed reconciler is chosen **by the type** rather than by a convention the compiler has to
  trust. Without it the build warns (W33).
- **`searchEffect api q _` is a placeholder, not a lambda.** `language.md` §6.7 allows at most one `_`
  per application, and this is the shape it was designed for. The two lambdas in `main` are the price
  of the same rule.
- **The `Api` record is not in the `Model`.** A model holding a function has no derived `eq`, which
  costs the `==` a test wants to write, and a time-travel diff (R25 §2.2).

> **SUPERSEDED 2026-09-29**: there is no desugaring to calls (W32); `language.md` §11.13 says what the plain-call form now is.

**And the plain-call form of one branch, because it is the same program.** `bir/Lower.zig` desugars
an element to exactly these calls, and an `emit/` golden proves the two emit identical bytes
(R28 rule 19, §10 objection 4):

```elm
Loaded hits ->
    Html.ul [ Html.class "results" ]
        [ Html.keyed (List.map hits (\hit -> ( hit.id, viewHit model hit ))) ]
```

### 1.2 The test, with no browser and no wall clock

*Depends on: **W16** (a `TestStore` in the platform), **A13** (a swappable clock), **A7** (services
are records). Unchanged from revision 1 — the rendering strategy is invisible to it.*

```elm
--! [proposed] `Browser.Test` and `Ref` (effects T0). Runs under the NODE
--! platform, in `tests/corpus/run/`, with no DOM: the TEA loop is DOM-free.
--! `program` is the record `main` builds, with the fake `Api` threaded in.
fakeApi : Ref (List String) -> Api
fakeApi calls =
    { search =
        \q ->
            let
                () = Ref.update calls (\c -> q :: c)
            in
            Ok [ { id = "1", title = q } ]
    , setFavourite = \_ _ -> Err NetworkError
    }


--| Type, type again inside the debounce window, advance the FAKE clock, and
--| assert the first query was never sent. 250 ms of debounce costs no wall
--| time, and the determinism test can run this at --jobs=1 and --jobs=8.
typeaheadDebounces : Ref (List String) -> Bool
typeaheadDebounces calls =
    let
        t0 = Test.start (program (fakeApi calls))
        t1 = Test.send t0 (Typed "a")
        t2 = Test.advance t1 (Duration.millis 100)
        t3 = Test.send t2 (Typed "ab")
        t4 = Test.advance t3 (Duration.millis 300)
    in
    Ref.get calls == [ "ab" ] && (Test.model t4).search.status == Loaded [ ... ]
```

Two end-of-test assertions are worth copying in spirit from TCA (R25 §9.6): *"the store received N
unexpected actions"* and *"an effect returned for this action is still running; it must complete
before the end of the test."* The second is only checkable because the runtime knows what is in
flight — which Elm's does not.

**And one addition in revision 2.** The same `view` can be tested with no browser at all, because
**W38's render-to-string platform is a second implementation of the same markup interface**:
`Test.render (view model)` returns a `String` and a `run/` fixture compares bytes. That is how rule 3
is satisfied for views before any browser slice exists, and it is what proves the markup interface is
a real interface rather than a browser API wearing a hat (R28 §8.3).

---

## 2. The kernel and the layers

*Depends on: **W25**, **W26**, **W3** (the scheduler), **W28**, **W6**, **W8**, **W29** (the
fallback).*

### 2.1 The kernel — five things, and everything else sits on them

R25 §10.1. The kernel is where the *guarantees* live; the architecture is a library.

1. **A root scope tied to the mount.** `Browser.element` opens a `Scope`; unmount closes it; every
   fiber below is interrupted, children first, finalisers run, and the caller waits (A1). This is the
   one guarantee no JavaScript framework can make. Solid arrived at the same disposal order
   independently and has shipped it for years, which is confirmation rather than coincidence
   (R27 §2.2).
2. **A `sync`, pure render.** The kernel's entry point demands a function that cannot suspend.
3. **A `sync` event→fiber bridge.** A DOM handler is `sync` so `preventDefault` works; starting a
   fiber from a handler is a kernel call, so the fiber is always parented in the root scope and can
   never be orphaned.
4. **Scoped subscriptions**, `bracket`-shaped: acquire is `addEventListener`, release is
   `removeEventListener`, and the scope owns both. Lustre's listener leak is unrepresentable.
5. **One frame-aware loop.** The kernel owns the render tick and the yield budget. Two libraries in
   one page must not each own a `requestAnimationFrame`.

**What revision 2 adds to the kernel's claim of neutrality.** Revision 1 said the kernel could host
four of R25's five architectures and not signals, because signals needed a fourth per-fiber slot.
**That was wrong** and is corrected: R27 §8.6 shows a plain module-level variable in the platform's
JavaScript is correct provided tracked computations are `sync`, which item 3 above already requires.
So the kernel hosts all five. Signals are unshipped and never forbidden (W19).

### 2.2 The pieces, and which side of the wall each is on

Rule 6: only a platform package may write `foreign`, so every line in the "JS" column is behind the
wall and is the platform's responsibility. Elm's equivalent is R24 §0.1's table. **Size estimates are
estimates** and §2.6 says what they are now worth.

| Piece | Elm's equivalent (R24) | Side | Guarantee it carries | Rough size |
|---|---|---|---|---|
| **Mount + model cell + dispatcher** | `_Platform_initialize` minus the bag machinery | **beni**, over a `Ref` | one source of truth; every message applied atomically (W25) | ~80 lines beni |
| **The render loop / animator** | `_Browser_makeAnimator`, 26 lines | **JS** | one render per frame; a render is never caught half-applied | ~40 lines JS |
| **Template extraction and hole paths** | *none — Elm has no equivalent* | **compiler** (`backend.md` §11) | the static structure of a view is built once, not described per frame | a compiler pass, W26/R1 |
| **The template runtime**: `cloneNode` from a `<template>`, the sibling walk, per-hole writes | `_VirtualDom_render` and the fact appliers, ~500 lines | **JS** | reads batched before writes (R26 §5.5: 1 139× otherwise) | ~1.7 kB brotli measured as a prototype (R29 §12.1); see §2.6 |
| **The per-hole check** | `_VirtualDom_diff*`, ~450 lines | **compiler-emitted JS** | `===` on an immutable value means "deeply unchanged" — **this is W27's promise, cashed** | emitted per hole |
| **The keyed list hole** | `_VirtualDom_diffKeyedChildren` | **JS** reconciler + **compiler** call site | a reordered list reuses the right DOM subtree (W33) | ~160 lines JS (`udomdiff`-shaped) |
| **The fallback tree path** | the whole virtual DOM | **undecided — W29** | correctness where the recogniser cannot prove the shape | §2.3, unmeasured |
| **Event registration and dispatch** | `makeCallback`, `applyEvents`, ~107 lines | **JS** + a `sync` beni closure | `preventDefault`/`stopPropagation` work (W8) | ~90 lines JS |
| **XSS sanitisers** | `VirtualDom.js:274-333`, ~60 lines | **JS** (four regexes) | a `view` cannot inject script — a rule-7 guarantee, and R24 §6.3 says there is no cheaper way | ~60 lines JS |
| **The element and attribute vocabulary** | none — Elm's is `elm/html` | **beni**, in the platform package | an unknown attribute is `unbound_variable` with "did you mean" (W37) | a few hundred lines of beni declarations |
| **The fiber kernel and scheduler** | `Scheduler.js`, 195 lines with no yield at all | **JS**, platform-neutral, the browser its first host | structured lifetimes, prompt cancellation, a page that keeps breathing | ~1 260 lines JS (r21 §0.4's estimate) |
| **The browser scheduler slot** | none | **JS** | input p90 ≈ the slice (R26 §3.3) | ~30 lines JS (W3) |
| **The command runner**: `Dict Key (Fiber ())`, four policies, key paths | `elm/http`'s effect manager, which only kernel code may write | **beni** | keyed cancellation as ordinary library code | ~80 lines beni |
| **Subscriptions**: the declared set, the diff, a scoped fiber per key | `Browser/Events.elm`'s three-way `Dict.merge` | **beni** over a JS registration primitive | a listener nobody wants stops, unwritten (W6) | ~80 lines beni, ~30 JS |
| **Navigation** | `_Browser_application`'s link guard and `popstate` | **JS** for interception, **beni** for the capability record | a single-page app cannot lose a click | ~70 lines JS |
| **`Browser.Dom`** — focus, viewport, `getElement` | `_Browser_withNode`, an rAF before every read | **JS** foreigns + W28's after-render point | a read sees the tree the program just described | ~90 lines JS |
| **Interop** — ports | `Platform.js:332-471` | **beni** codec, generated; **JS** transport | a malformed payload is a `Result`, not a crash | B3's, already specified |
| **Defect teardown + screen** | none — Elm wedges silently | **JS** flag + `AbortController`, **beni** report | nothing runs on state nobody can vouch for (W2) | ~40 lines JS |

**What moved.** Revision 1 had four virtual-DOM rows totalling ~1 000 lines, of which ~550 were to be
written in beni (node construction and the diff), and it called that *"the plan's most load-bearing
feasibility claim"*. All four are gone. What replaces them is a **compiler pass** plus a **small
JavaScript runtime**, and the beni side of the renderer shrinks to the element vocabulary — which is
declarations, not algorithm. The one thing that got *harder* is the fallback (W29), and it is the one
thing that is not designed.

### 2.3 What the compiler emits, and what the runtime behind the wall does

*Depends on: **W26**, **W29**, **W37**. This replaces revision 1's "can the diff really be written in
beni?", which was answering a question that no longer exists.*

> **SUPERSEDED 2026-09-29**: markup lowers to its own instruction, not to calls, and templates are what it always compiles to (W32; `frontend.md` §9.7). The shape below is still the shape of a row (`backend.md` §15.5).

**The seam.** JSX desugars in `bir/Lower.zig` to ordinary saturated calls —
`Html.div [ Html.class "x" ] [ kid ]` — so BIR contains no markup and every existing pass works
unchanged (R28 §8.1). A **later, `--release`-gated pass recognises that call shape structurally** and
replaces it with a template and holes. Recognising rather than lowering separately is what makes the
plain-call form get the same treatment, which is rule 7's answer to "two ways to write the same
thing" (R28 §10 objection 4). Leptos proves the predicate is structural rather than syntactic: its
default strategy is an `is_inert_element` walk that collapses any subtree with no components, blocks
or special attributes into one static string.

**What the pass emits, for one row of a table** (R29 §7.1's `p2-tpl`, which is the measured shape):

```js
// 1. the static markup, once per template, hoisted and deduplicated on markup alone
const ROW_TPL = document.createElement("template");
ROW_TPL.innerHTML = '<tr><td class="col-md-1"> </td>…</tr>';
const ROW_PROTO = ROW_TPL.content.firstChild;

// 2. the mount: one native subtree clone, then a compile-time sibling walk to each hole
function makeRow(row, selected) {
  const el = ROW_PROTO.cloneNode(true);
  const idT = el.firstChild.firstChild;                        // hole path [0,0]
  const lbT = el.firstChild.nextSibling.firstChild.firstChild; // hole path [1,0,0]
  idT.nodeValue = row.id;  lbT.nodeValue = row.label;
  return { el, row, sel: row.id === selected, idT, lbT };
}

// 3. the update: ONE reference comparison per hole. `row === inst.row` IS the strategy.
function updateRow(inst, row, selected) {
  if (inst.row !== row) {
    if (inst.row.label !== row.label) inst.lbT.nodeValue = row.label;
    inst.row = row;
  }
  const sel = row.id === selected;
  if (inst.sel !== sel) { inst.el.className = sel ? "danger" : ""; inst.sel = sel; }
}
```

**Five properties of that shape, each with its evidence.**

1. **Template cloning beats every other way of building markup.** Building 1 000 rows into a detached
   `<tbody>`: `cloneNode` from a `<template>` **2 653 µs**, `createElement` chains 3 822,
   `innerHTML` of the whole body 4 620, a virtual DOM's create path 4 658 (R29 §11.4). 1.44× over
   `createElement` and 1.76× over the vdom. `innerHTML` being slowest is worth recording, because it
   is the opposite of most people's intuition.
2. **Static attributes cost nothing at run time**, because they are baked into the template string.
   Solid's instrumented 1 000-row mount shows `setAttribute: 0` and `createTextNode: 0` (R27 §6.2).
3. **The per-hole check is ~1 ns in a tight loop over dense arrays and ~68 ns per row in a real
   renderer** that iterates a `Map` and touches three fields of an instance object (R27 §5.5,
   R29 §7.4). **Use 68 ns, not 1 ns, when setting a budget** (W36) — and note that a renderer keeping
   its instances in a dense array parallel to the model would be nearer the floor.
4. **An unchanged row costs one pointer compare and zero allocations.** That is the whole of W27's
   identity promise, cashed. It is also why a compiled template retains **189 bytes of JavaScript
   heap per row against a signal graph's 977 and a virtual DOM's 790–859** (R29 §9.1).
5. **The `moved` flag means the keyed reconciler is not even entered when nothing moved**, which is
   the common case for a selection change or a label edit (R29 §7.1).

> **SUPERSEDED 2026-09-29**: `For` replaces `Keyed msg` (W33), with the same reconciler — `backend.md` §15.5.

**The keyed list hole.** `Keyed msg` (W33) compiles to a `key → instance` map plus an array
reconciler — R29 used `reconcileArrays` from `dom-expressions`, itself WebReflection's `udomdiff`,
with the `$$SLOT` ownership tags dropped because a whole-program compiler assigns every node exactly
one owning slot (R27 §6.11). **So beni and Solid use the same array reconciler**, and any difference
between them is not the reconciler. Do **not** copy Elm's keyed diff: it is a single forward pass with
one element of lookahead, so "swap rows 1 and 998" falls to its `break` path (R24 §6.5).

**Events, and the one rule that is not obvious.** Delegation is a single property write plus one
`delegateEvents` call for the whole program: Solid's instrumented mount of 1 000 rows shows
**`addEventListener: 1`** for a thousand handlers (R27 §6.2). beni can always take Solid's
fast path, because Solid only falls back to its runtime helper when the handler is not a resolvable
function and beni always knows. **And the node representation must carry the handler's *variant* as
data beside the closure** — `Normal` / `MayStopPropagation` / `MayPreventDefault` / `Custom` — because
the variant decides the listener's `passive` flag (R24 §6.6, W34). beni cannot compare two closures
for equality, so Elm's design (a *stable* JS callback whose handler lives in a mutable field, giving
zero add/remove pairs for a fresh closure each frame) is not an optimisation for beni; it is the only
workable design.

#### The fallback path, and why it is not designed here

> **ANSWERED 2026-09-29** (research 36 question 3): escaping markup is a block that patches when it is the same kind and remounts otherwise — `backend.md` §15.4.

**This is W29 and it is open.** The shape above assumes the recogniser can see the whole path from a
root template to every hole. It can when `view` is one literal expression. It cannot when an
`Html msg` value escapes — and §1.1's own view does that three times: `{viewStatus model}` is a
helper's result in a hole, `List.map hits (\hit -> … viewHit model hit)` puts `Html msg` values
through a list, and a component's `children` field holds one. Add recursion — a tree widget — which
cannot be inlined at all.

Three shapes are on the table, and **[`plans/browser-decisions.md`](browser-decisions.md) W29 states
them and §5 risk 1 names the experiment (X1) that chooses between them**: inline everything; make a
mounted template instance a real `Html msg` value at the seam; or keep a small tree-and-diff as the
fallback for subtrees the recogniser cannot prove.

**What the plan commits to regardless of the answer**, because all three need it:

- **`backend.md` §11 must define the fallback before it defines the fast path**, so that "what
  happens when the recogniser fails" is a specified behaviour rather than a bug found later.
- **The pass must be able to report what it did.** A view that is fast until someone extracts a
  helper, with nothing saying so, is a silent cliff. A `dump` stage or a `--release` report naming
  the holes that fell back is the mitigation, and it is cheap.
- **The template id must be derived from the module index and the instruction index, never from a
  counter shared across workers.** That is the one place a template-lowering implementer can break
  rule 5, and it belongs in the spec (R28 §9.3). Dioxus needed a compile-time content hash for the
  same problem arriving by another door.
- **Development output must not move.** The `--release` slice's proof was *"development output did
  not move by one byte"*; a `--release`-gated template pass can make the same claim, and the `emit/`
  corpus is what makes it a test.

### 2.4 The render loop contract

> **Items 1–2 SUPERSEDED 2026-09-29** by W28: Solid 2's microtask flush and an explicit `flush()` (`backend.md` §15.11). Items 3–6 stand, and 3–4 are specified in `backend.md` §15.11.

*Depends on: **W28**.*

1. **One render per frame.** N messages between frames cost N model writes and one
   `requestAnimationFrame`. Measured in Elm: five messages in one synchronous loop → one DOM update,
   on the next frame (R24 §6.9). **And frame batching is worth more to a template renderer than it is
   to Solid**, not less: Solid renders once per microtask flush and gets away with it because its
   graph already skips unaffected work, whereas a top-down re-run would duplicate the whole view pass
   (R27 §3.6).
2. **An explicit "render now",** for the case Elm documents: a `<input type="text">` holds its own
   state and a fast typist outruns the frame. Elm reaches this by an unrelated-looking API choice —
   `// stopPropagation implies isSync` — and beni decides the two separately.
3. **One after-render suspension point.** `Browser.afterRender ()` parks until the pending view has
   been applied, so `afterRender (); Dom.focus "search"` is the sequencing written down instead of
   hidden. Better than Elm in one way: `_Browser_withNode` costs a frame *unconditionally*, even when
   the node has existed for minutes, where `afterRender` can return immediately when nothing is
   pending.
4. **The hole pass batches reads before writes**, and nothing in it may suspend. R26 §5.4: a rAF
   callback that hopped one macrotask resumed 10.1 ms later and its write landed in the *next* frame.
   R26 §5.5: interleaved read/write over 3 000 nodes cost **2 846 ms against 2.5 ms** batched.
5. **The frame budget is real.** R26 §5.6, headless Chrome: 4.7 ms of work per frame is free, 18.6 ms
   costs a frame, 55.8 ms costs four. (No display, no vsync, so frame *jitter* is not represented.)
6. **A published change-detection budget: 1 ms at 60 Hz**, from "`update` returned" to "the DOM is
   consistent with the model", excluding layout and paint (W36). Every strategy R29 measured except
   the plain virtual DOM meets it at 1 000 rows with an order of magnitude to spare.

### 2.5 One obligation the reports have separately and nobody joined

*Depends on: **W25**. This is a design obligation, not a question. Unchanged from revision 1.*

`Send msg` is `sync (msg -> ())` and re-enters the dispatcher synchronously. So a fiber's `send`
calls `update`, which may return a command that spawns a fiber, which may send again — **inside the
first send**. Elm has exactly this hazard and guards it with a queued dispatch and a nineteen-line
comment naming three issue numbers (R24 §2.4), and R24 says in terms that *"beni's fiber runtime has
the same class of problem"*. It is the same class as the re-entrant interrupt the effects spike
already owns. **The dispatcher needs a drain flag or a queue, specified before it is written, with a
fixture.**

### 2.6 The size budget, re-derived

*Depends on: **W11**. Revision 1's figure assumed a virtual DOM and is now an estimate of the wrong
thing.*

**What revision 1 said.** R24 §11.4 estimated a beni counter at **35–50 kB raw**, against Elm's
109 530 B raw / 22 723 brotli, and said plainly it was *"an estimate from the column above, not a
measurement"*. That column was a byte attribution of an `--optimize` Elm counter in which the virtual
DOM is **29 782 B, 27.2 % of the whole** (R24 §11.3).

**What changes.** The virtual DOM is gone, and R29 §12.1 measures what replaces it — with a large
caveat attached. The template prototypes are **1 682–1 808 bytes brotli, minified**, against a signal
runtime's 22 375 and ivi's 3 878. They are *not shipping renderers*: they contain no element or
attribute vocabulary, no event system beyond one delegated `click` listener, no XSS sanitisation, no
`requestAnimationFrame` batching, no subscriptions, no scheduler and no fiber runtime.

**So the honest form of the budget is a decomposition, not a number:**

| Layer | Estimate | Source and confidence |
|---|---|---|
| beni's runtime-free floor today | 2 147 B raw / **833 brotli** | measured (`backend.md` §9) |
| the template runtime (clone, hole walk, per-hole writes, keyed reconciler) | **~1.7 kB brotli** | measured as a prototype, R29 §12.1 — a lower bound |
| XSS sanitisers | ~60 lines | R24 §6.3: *"there is no cheaper way to get it"* |
| events, delegation, the `passive` variant | ~90 lines JS | estimate, R24 §6.6's shape |
| the animator and after-render phase | ~40 lines JS | estimate |
| the element and attribute vocabulary | **unknown, and it is the big one** | it is beni declarations, so `Reach.zig` drops what a page does not use — which is exactly why Elm's per-file kernel DCE cannot (R24 §11.3) |
| the fiber kernel and scheduler | ~1 260 lines JS | r21 §0.4's estimate; not browser-specific, and **not loaded by a page with no effects at all** |

**The one claim worth making now**, because it is the difference the measurement actually supports:
**a template renderer is ~1.7 kB brotli of machinery where a signal graph is ~22 kB**, and whatever
else a platform adds, it adds to both (R29 §12.1). For comparison from Solid's own side: with its
reactive core bundled in, `{template}` alone is **255 brotli bytes** and `{template, insert}` is
**10 350** — *"one dynamic text hole costs 10 kB"*, because `insert` is the door to the reactive core
(R27 §6.9). beni's version of that door is a compiler pass.

**Two things the budget must not do.** It must not quote effects' ≤ 5 kB gzip figure, which covers
the fiber kernel only (R25's F10, `plans/effects-decisions.md` B9). And it must not quote R29's
prototype brotli figures as a platform target. **W11's number is set after slice R1 has a real
emitter and B1 has a real platform**, and not before.

### 2.7 Interop, navigation and the defect screen, in one paragraph each

- **Interop** is `boundary.md` §3.1's ports, already specified and already better than Elm's: a codec
  generated from the declared type, a depth bound, and a decode failure **as a value** where Elm's is
  `__Debug_crash`. The distinction to keep: a bad payload is malformed input from *outside* the wall,
  which is what a `Result` is for, and not a defect in A1's sense. What is new is the *other*
  direction — a `foreign` that holds a beni closure and calls it from a listener — which is W8 and a
  gap in `boundary.md` §4.
- **Navigation** is a capability record (A7), not Elm's opaque `Key` phantom: `nav.pushUrl url`, which
  is the same unforgeability and is additionally testable with a fake (R24 §7.3). Preserve Elm's
  asymmetry: `load` and `reload` take no capability, because a full page load cannot desynchronise a
  router that is about to be destroyed. The link-click guard copies across unchanged: no modifier
  keys, primary button, no `target`, no `download`, then `preventDefault`.
- **The defect screen** is W2's (b)+(c): a `dead` flag the scheduler and every listener test, a single
  `AbortController` that removes every listener the platform installed, the root scope closed so
  finalisers run and requests abort, and — **in development builds only** — a report written into the
  root. Solid does the first half and not the second, and its own issue #3338 comment says why that
  is a problem (R27 §9.2). It is `plans/queue.md` row 54 with a browser half.

---

## 3. Order of work — the tracks and the slices

Each slice: goal · what it proves · its black-box test kind · what it needs from the effects spike ·
exit criterion.

### What needs effects, and what does not — the most useful fact in this document

**Today nothing in beni can suspend.** There are no fibers, no effects, no `sync` keyword. So a TEA
loop with no commands and no subscriptions is an ordinary total program, `sync` is vacuously true of
every function in it, and **the entire language track, the entire rendering track, the core item and
the first two browser slices can be built and tested with no effects work at all.**

| Track | Needs from effects |
|---|---|
| **L** — JSX: parser, formatter, desugar, typed holes, the identity promise | **none** |
| **R** — templates: the recogniser, the keyed list hole, the field analysis | **none** |
| **C** — an indexable sequence in `core/` | **none** |
| **X** — the three experiments | **none** (they are read-only scratchpad work) |
| **O** — output: the bundle, sibling minification, source maps | **none** |
| **B0, B1** — the browser harness and a static render | **none** |
| **B2′, B3** — the renderer in a page, the TEA loop | **none today**; **S2 + S3** (the two bits, then `sync`) once anything can suspend, because that is when the `sync` handler rule stops being vacuous |
| **B4 onward** — the fiber kernel, commands, subscriptions, the defect screen | **S4–S11** |

**The one consequence to plan around**: the `sync` keyword does not parse yet, so L and R work is
written without it and the annotations gain it when S3 lands. That is a mechanical edit across the
platform's signatures, and it is the only thing the ordering costs.

### The language track — JSX *(needs nothing from effects)*

| # | Slice | Depends on |
|---|---|---|
| **L1** | JSX as pure sugar: parser, formatter, desugar, and a render-to-string platform | W30, W31, W32, W38 |
| **L2** | Typed child holes and the attribute vocabulary in the checker | L1, W33, W34, W37 |
| **L3** | The identity promise, specified and pinned | W27 |

> **SUPERSEDED 2026-09-29** by MJ1–MJ5 (§7): text is bare (W30), markup is not sugar (W32), and the render-to-string platform is the `node` platform's `ssr` lowering.

**L1 — JSX as sugar.** *Spec first (rule 1): `language.md` §3's grammar, a new subsection beside
*Evaluation order* carrying R28 §11.1's twenty rules, §9's formatting rules and §10's new codes
appended never inserted; `frontend.md`'s new §9.*
- *Goal.* `parseElement` on `op_lt` at operand start; quoted text children; a tag name resolved as an
  ordinary name; attributes desugared to calls in the tag's namespace; `bir/Lower.zig` producing
  **exactly the calls the plain form produces**. Plus a **render-to-string platform**, which is a
  second implementation of the markup interface and is what lets `tests/corpus/run/` execute a view
  under Node where there is no DOM.
- *Cost.* ≈1 300–1 900 lines of Zig, of which **0–30 are in the lexer** and 80–150 in the checker
  (R28 §9.1). One new token (`...`) or a different spelling for spread; two parser-level joins.
  **No lexer mode**, which is what keeps the >250k LOC/s budget safe by construction (R28 §9.2), and
  **no change to the interface hash or the M4 cache format** beyond a new token enum value, which the
  compiler-build-id key already invalidates (R28 §9.3).
- *Test kind.* `fmt/` for the formatter (idempotence, attribute break-all, closing-tag alignment);
  `check/bad/` for `unclosed_element`, `mismatched_closing_tag`, `element_as_argument`,
  `duplicate_attribute`; **`emit/` for rule 19**; `run/` for the rendered string.
- *Exit.* **Three things, and the first is the whole point.** (1) An `emit/Jsx*.js` golden is
  **byte-identical** to the `emit/` golden of the same view written as `Html.div [] []` — that is what
  makes "two ways to write the same thing" a spelling rather than a second language. (2) §1.1's
  `view`, `viewStatus` and `viewHit` render to the expected string in a `run/` fixture under Node.
  (3) `zig build bench` shows no regression on a markup-free corpus, and a markup-heavy corpus is
  added so the question can be asked at all — R28 §15 records that nobody has measured one because
  none exists.

> **SUPERSEDED 2026-09-29** by MJ4 (§7) and `checker-v2.md` §25: the hole set has no `Keyed msg`.

**L2 — typed child holes and the vocabulary.**
- *Goal.* `checker.md` §6.1 gains one obligation — `renderable(var, region)` beside `equatable`,
  `interpolatable`, `tuple_index` and the method obligation — with its discharge arm in §6.4 and
  `child_not_renderable`'s message in §8. The accepted hole types are `String`, `Int`, `Float`,
  `Bool`, `Char`, `Html msg`, `Maybe (Html msg)`, `List (Html msg)`, `Keyed msg` (R28 §4.4). The
  element and attribute namespace is a platform package's `pub` declarations (W37).
- *What it proves.* That **no `Html.text` wrapper is ever written** and that an unknown attribute is
  `unbound_variable` with "did you mean" — which is better than any of the prior art, because
  Leptos's and Dioxus's unknown-attribute error is whatever rustc says about a missing method with
  the view type spliced in (R28 §2.4).
- *Rule 7.* The closed hole set is a restriction and it buys a guarantee: every hole has a known
  update strategy, so nothing renders through a generic `toString` the release optimiser is free to
  change. The escape hatch never closes — `Html.text (myRender x)` is always available.
- *Exit.* `child_not_renderable` names the type and the accepted shapes; the typeahead compiles with
  no wrappers; a `check/bad` fixture per code.

> **KEPT 2026-09-29**, specified as `language.md` §11.12 and pinned per `backend.md` §15.8; built in MJ4–MJ5 (§7).

**L3 — the identity promise, specified and pinned.** *This is the slice that makes W26 sound.*
- *Goal.* One paragraph in `language.md` §6: **an update preserves the identity of every field it does
  not name, and no optimiser pass may break it.**
- *How a black-box test can possibly assert it*, since beni has no reference equality: **two ways,
  and both are needed.** (1) `emit/` goldens pinning the spread shape — `({ ...p, x: … })` — under
  **both** the development and the `--release` build, because `--release` is where an optimiser would
  break it and the corpus already builds every `run/` program a second time under the flag. (2) A
  test-only `foreign refEq : a, a -> Bool` in the **render-to-string platform** (rule 6 permits it;
  only platforms may write `foreign`), so a `run/` fixture can assert
  `refEq model.rows (update (Select 3) model).rows` directly. Without (2) the promise is pinned by
  shape and not by behaviour.
- *Exit.* Both fixtures fail before the guarantee is written and pass after; a deliberately-broken
  optimiser pass makes (2) fail.

### The rendering track — compiled templates *(needs nothing from effects)*

| # | Slice | Depends on |
|---|---|---|
| **R1** | The template recogniser and lowering — `backend.md` new §11 | W26, **W29 via X1**, W37 |
| **R2** | The keyed list hole and the unkeyed warning | R1, W33 |
| **R3** | The field-dependency analysis, and the selector pattern only if asked | R1, W42, **X3** |

> **SUPERSEDED 2026-09-29**: templates are not a `--release`-gated recogniser but what markup compiles to, always (W32); the lowering is platform code (`boundary.md` §9.4, `backend.md` §15). Its exit table survives as MJ9's bar (§7).

**R1 — the recogniser and the lowering.** *Spec first: `backend.md`'s new §11.*
- *Goal.* A `--release`-gated pass over BIR that recognises the `Html.*` call shape, extracts a
  template, computes hole paths, and emits the mount/update pair of §2.3. Plus the platform-declared
  well-known runtime names (W37) and the fallback (W29).
- *Cost.* ≈600–1 000 lines of Zig (R28 §9.1's lowering (ii) row), plus the JavaScript runtime.
- *Test kind.* `emit/release/` for shape — it is already the golden directory for release-shape
  claims. `run/` through the render-to-string platform for behaviour with no browser. `browser/` for
  behaviour in a page, once B0 exists.
- *Exit — and this is where the owner's requirement is met or not.* **A real compiler-emitted P2 is
  re-measured against Solid 2 with R29's own harness.** The bar, from R29 §5.4's script medians at
  1 000 rows under the benchmark's official throttling:

  | operation | Solid 2.0.0-rc.9 | the P2 prototype | the emitter must |
  |---|--:|--:|---|
  | create 1k | 3.88 | 2.45 | beat Solid 2 |
  | replace 1k | 9.17 | 7.00 | beat Solid 2 |
  | update every 10th | 2.35 | 1.08 | beat Solid 2 |
  | **select** | **2.60** | **1.71** | **beat Solid 2 — this is the discriminating operation** |
  | swap | 1.29 | 0.88 | beat Solid 2 |
  | remove | 0.83 | 0.51 | beat Solid 2 |
  | create 10k | 50.98 | 30.06 | beat Solid 2 |
  | append 1k | 4.55 | 2.70 | beat Solid 2 |
  | clear | 18.04 | 16.76 | beat Solid 2 |

  **Four rules for reading that table when the time comes.** (i) **Re-run Solid 2 in the same batch on
  the same machine**; never compare against these stored numbers, which are machine- and
  load-dependent. (ii) **Judge on the per-operation script medians, never on a geometric mean** — the
  manager's re-run reproduced the ordering and the per-op medians to ~10 % but moved a
  ratio-of-ratios headline by 27 %, and R29 now records a noise floor of about ±0.25 on that column.
  (iii) Allow the emitter **up to 20 % worse than the hand-written prototype** and still call it a
  pass; it is a different kind of artefact and R29 §14 says the gap is unmeasured. (iv) Also re-run
  R29's **E1 static-heavy page** (2 000 elements, 50 holes, one changing), because the table benchmark's
  list hole is the whole app and E1 is the shape almost every real screen has.

> **SUPERSEDED 2026-09-29**: no `Keyed msg`; lists are `For` (W33), warned by `unkeyed_for` — MJ7 (§7).

**R2 — the keyed list hole.**
- *Goal.* `Keyed msg` from `Html.keyed`, the `udomdiff`-shaped reconciler behind the wall, and the
  default-on root-package warning `unkeyed_list_hole` with `Html.unkeyed` as the named escape.
- *What it proves.* That a reordered list reuses the right DOM subtree, which is the one correctness
  property the whole rendering strategy cannot get from reference equality alone.
- *Test kind.* `browser/` — a list reordered with a focused input inside a row, asserting the focus
  followed the row. Plus a `check/` fixture for the warning and one for the escape hatch silencing it.
- *Exit.* The focus test passes keyed and fails unkeyed (which is the point of the warning); the
  warning fires exactly once per unkeyed hole in the root package and never in a dependency.

**R3 — the field-dependency analysis.** *Do not start this before **X3** has retired the Svelte-5
question (§5 risk 5).*
- *Goal.* Rung 3: a per-hole free-variable analysis over the view body — an ordinary use-def walk —
  so a message that changes one model field visits only the holes that read it.
- *What it is worth, honestly.* `select` 1.71 → 0.49 ms of script at 1 000 rows, of which **four
  fifths is the field diff and one fifth is the separate selector pattern** (R29 §7.4). And on a page
  where each hole has a field to itself it is *marginally slower* than R1 — 3.5 µs against 2.25 —
  because a field-level diff is then exactly the comparisons the per-hole check already did (R29
  §11.1). **The analysis pays where one field feeds many holes, and not otherwise.**
- *What it costs the compiler is unmeasured*, because there is no implementation (R29 §14). It is a
  walk over one function body against a >250k LOC/s budget, so the expectation is noise; that is an
  expectation, not a measurement, and the slice must publish the number.
- *Rung 4, the equality-keyed selector, is not part of this slice* and is W43. The option to refuse
  is a platform `createSelector` the programmer writes: it is a performance annotation whose absence
  is silent and whose presence says something the compiler can already see.

### The core item *(needs nothing from effects)*

**C1 — an indexable sequence.** *Depends on **W35**, and on **X2** first.*
- *Goal.* `core/Array`: `get`, `set`, `push`, `slice`, `length` in O(1), and `List` interconversion.
- *Why, and it is not speed.* R29 §10.3 measures beni's real compiled `update` for "swap rows 1 and
  998" at **81× an array's at 1 000 rows and 64× at 10 000** — but the absolute worst case is 0.21 ms,
  1.3 % of a frame. **The finding is that `get` does not exist**: a beni program cannot name element
  *i* of a sequence in better than O(i), `List.length` is a fold (20.8 µs at 10 000 rows), and a
  renderer must materialise an array to reconcile. Rule 6 means an ordinary developer cannot fill
  that gap; rule 7 says the language is therefore withholding it.
- *What X2 must settle first.* R29 §10.4 is explicit: its "array" column is a **copy-on-write
  JavaScript array**, not a persistent vector, and a 32-way trie loses to a plain copy-on-write array
  for `Append`, `Remove` and a full walk. **Nobody has measured which shape beni should ship.**
- *Exit.* `backend.md` §4's parked *"pending M3c's benchmark of a vector trie"* is discharged with a
  written answer; the corpus's `Swap`-shaped fixture is O(1) rather than three walks.

### The experiments *(read-only, scratchpad, no compiler change, no answered W required)*

| # | Experiment | Retires | Size |
|---|---|---|---|
| **X1** | **The fallback-tree experiment.** Take R29's `p2-tpl` harness and §1.1's typeahead. Write the view three ways — everything inline (best case); helpers returning `Html msg` into holes (idiomatic, which is what §1.1 actually is); one hole whose subtree the recogniser is told it may not see through (worst case). Hand-emit the three candidate shapes — full template; template with a mounted-instance seam; template with a diffed subtree. Measure per-message script on R29's E1 page and on the 1 000-row table. **Deliverable: the fraction of a realistic view that falls back under each option, and the per-message cost of the seam.** Fold in W39's unmeasured question at the same time: does a nested model's two small clones plus the extra hole indirection beat one wide clone in a real view? | **W29**, the design's one open technical question, and **W39** | one prototype page, comparable to one of R29's |
| **X2** | **Which array.** Copy-on-write JS array against a 32-way persistent trie against today's cons list, on `get`, `set`, `push`, `append`, `filter`, `map` and a full walk, at 1 000 and 10 000 elements, with retained-heap-per-element beside each. Use R29's `listmicro.js` harness and beni's own compiled `update` where possible | **W35**'s second half | half a day |
| **X3** | **Why Svelte 5 replaced compile-time invalidation with signals.** Primary sources: Svelte's own runes RFC and announcement, the `$$invalidate`/`$$dirty` code in a Svelte 4 tag, and whether the 31-bit-per-component ceiling is discussed in the migration notes. **If the reasons are Svelte-specific they do not transfer; if they are fundamental to compiler-derived dependency graphs they kill R3** | **W42**'s risk | half a day, read-only |

### The browser track *(revised)*

| # | Slice | Needs from effects | Depends on |
|---|---|---|---|
| **B0** | The browser test harness as a corpus kind | **none** | — |
| **B1** | Platform package skeleton, `main` for a page, a static render | **none** | B0 |
| **B2′** | The **template renderer** and events with `sync` handlers | **none today**; S2 + S3 once anything can suspend | B1, L1, R1, W8 |
| **B3** | The TEA loop with a pure `update`, no effects | **none today**; S3 later | B2′, W25 |
| **B4** | The fiber kernel hosted on `MessageChannel`, with the slice rule | **S4, S5, S6, S11** | B3, W3 |
| **B5** | Commands as fibers with `send`, keyed scopes, cancellation | **S6, S7, S8, S10, S11** | B4, W25, W7 |
| **B6** | Subscriptions | **S8** | B5, W6 |
| **B7** | Navigation | none beyond B5 | B5 |
| **B8** | Interop (ports) | none | boundary milestone B3 |
| **B9** | The defect screen and crash reporter | **S9** | B4, W2 |
| **O1** | The single-file `--release` bundle | **none** | — |
| **O2** | Minifying sibling JavaScript | **none** | O1, W14 |
| **O3** | Source maps | **none** (S4's lowering must not foreclose them) | — |

**B0 — the browser test harness as a corpus kind.** *No effects work, no platform, no compiler change.*
- *Goal.* A `tests/corpus/browser/` kind driven by one long-lived headless Chrome, a fresh `Target`
  per fixture, up to 8 in flight, with CDP virtual time on by default for any fixture that mentions
  time.
- *Exit.* **≤ +2 % of `zig build test-blackbox`.** R26 §9.1 measured 10.0 ms per fixture at 8-way
  parallelism against a gate of 1 m 50 s for 668 fixtures; 125 browser fixtures cost 1.3 s, +1.2 %.
  Process reuse is worth **15×** and is the single decision that matters.
- *What happens with no Chrome.* **Skip loudly, never silently pass.** The DOM emulators are not an
  answer: `jsdom` and `happy-dom` are 13–28× more expensive per fixture **and neither has
  `MessageChannel`** — the exact primitive W3 builds the scheduler on (R26 §9.2).
- *Also settles.* W15 (virtual time: 50 000 ms of chained timers in 0.9 ms of real time) and W9's exit
  convention.
- *As built, 2026-09-29* (`tests/blackbox/browser.zig`, `tests/corpus/README.md` *`browser/`*).
  **The gates run the page under happy-dom in Node; Chrome is `zig build test-browser`**, the reverse
  of the goal above, decided on new measurements. Research 26 §9.2 timed each emulator in a fresh process
  from `node_modules`; bundled into one vendored file, happy-dom 20.14 costs 115 ms of CPU per page
  against bare Node's 30 (linkedom 56, jsdom 705), and one Chrome costs 36 ms of CPU per target
  after 0.7 s to start — comparable per page, but a shared browser fits neither the per-case
  instruction budget nor the flake's default shell (Chromium is 454 MiB, Linux only), and a skip
  whenever Chrome is missing would leave the gate unproven on most machines. happy-dom matched
  Chrome on seven of eight probes (`<!>`, implied `<tbody>`, `<template>` content, `value` against its
  attribute, checkbox activation, focus, a listener's exception); linkedom failed seven, including
  dropping everything after a `<!>`. `MessageChannel` is Node's own. **Not built: virtual time**
  (no fixture needs a timer yet) — it belongs to `test-browser` first, and to the scheduler slice.

**B1 — the platform package, `main` for a page, a static render.** *No effects work.*
- *Goal.* `platforms/browser/` with a `beni.json` declaring `program` and `runtime`, a `Program` that
  is a mount descriptor, and a `view` with no events rendered once into a root node.
- *What it proves.* That the artifact shape and the `runtime` hand-off need no compiler change —
  exactly as R26 §8.1 found when it loaded a Node-built program in a browser by replacing **one** file.
- *Exit.* The empty mounted page's floor measured, dev and `--release`, into `bench/size.mjs`. First
  half of W11; today's runtime-free floor is 2 147 B raw / 833 brotli.

> **SUPERSEDED 2026-09-29** by MJ6–MJ7 (§7).

**B2′ — the template renderer and events.** *Replaces revision 1's B2, which built a virtual DOM.*
- *Goal.* §2.3's renderer in a page: the template runtime behind the wall, the compiler's mount/update
  pair from R1, delegated events, handlers `sync` and carrying a variant, XSS sanitisers.
- *What it proves.* W26 end to end, W8's registration rule, and R1's numbers in a real page rather
  than in a prototype.
- *Test kind.* `browser/` for behaviour (a keyed list reordered, a controlled input, a
  `preventDefault`ed link that does **not** navigate) plus `emit/release/` for shape. A `check/bad/`
  fixture for a handler that suspends, once `sync` exists.
- *Exit.* The counter's bytes, dev and `--release`, against R24 §11.3's Elm decomposition (Elm's
  virtual DOM alone is 29 782 B, 27.2 % of a counter); `addEventListener` called **once** for a
  1 000-handler list, which is Solid's measured figure and is the delegation working (R27 §6.2).

> **SUPERSEDED 2026-09-29** by MJ8 (§7): the loop is W28's microtask flush, and TEA is the `browser-tea` platform.

**B3 — the TEA loop with a pure `update`.** `Browser.element` with `init`/`update`/`view`, no commands,
no subscriptions; the model cell, the dispatcher with §2.5's re-entrancy guard, and the animator.
*Proves* R24 §6.9's frame contract holds in beni. *Test:* `browser/`, plus a DOM-free `run/` fixture
under Node driving the same loop through the render-to-string platform. *Exit:* five messages in one
turn produce one DOM mutation; the render-now path produces five.

**B4 — the fiber kernel on `MessageChannel`.** *Needs S4, S5, S6, S11.* W3's rule: count 256 ops, read
`Date.now()`, yield through `MessageChannel` on a 1 ms slice. *Proves* **R26's numbers with a real
beni fiber** — R26 could only use a 465 ns stand-in. *Exit:* input p90 **≤ 2 ms**; yield overhead
**≤ 1.02×**; zero `longtask` entries. And the negative control: the microtask variant must reproduce
R26 §3.2's catastrophe, or the harness is not measuring what it thinks.

**B5 — commands as fibers, keyed scopes, cancellation.** *Needs S6, S7, S8, S10, S11.* §1.1's `Cmd`:
`perform`, `performKeyed`, `cancel`, the four policies, key paths pushed by `Cmd.map` (W7). *Proves*
the whole architecture. *Test:* `run/` under Node with a fake clock and a fake `Api` — §1.2's
typeahead — **and** a `browser/` fixture that mounts, starts a request, unmounts, and asserts the
listener was removed and the request aborted from the closing of **one** scope. *Exit:* one `search`
call for two keystrokes inside the debounce window; cancellation latency **≤ 60 ms** in a page (R26
§6.1 measured the owned-continuation path at 50 ms against native `async` + `AbortController`'s 301).

**B6–B9** are unchanged from revision 1: subscriptions (S8), navigation, ports, and the defect screen
(S9). B9's exit is that after a defect no further fiber resumes, no listener fires, and the
`AbortController` has fired — verified in the page.

### The output track, which is independent of everything above

**O1 — the single-file `--release` bundle.** *No dependency on anything in this plan or in effects.*
`backend.md` §10 already specifies it and states that *"with one entry point and no `lazy`, a release
build is exactly one file"* — the degenerate case needs no colouring lattice, no merge pass and none
of §10's PENDING decisions. *Exit:* §10's acceptance criterion 1 (`split_brotli_bytes ==
brotli_bytes`), every `emit/` and dev golden byte-identical, and R26 §8.2's **3.0× to `main` on 4G**
reproduced. *Caveat:* that figure is HTTP/1.1; over HTTP/2 the `modulepreload` alternative improves
and the bundle row does not. R29 §12.2 sees the same shape from another angle: the nine-file
prototypes pay **19.8 ms of resource time against 2.4** even on localhost.

**O2 — minifying sibling JavaScript.** *Depends on **W14**.* Siblings are **71.6 %** of
`Dictionaries`' raw bytes and whole-line comments are 42 % of the tree; bundling with minification
takes it 6 380 → **3 269** brotli (R26 §8.3), and R29 §12.1 measures the same gap on a nine-file
prototype at **2.8×** (10 592 as served against 3 758 minified). **What minification must preserve:**
`boundary.md` §4's checks read the sibling's *source text* — check 4 counts the parameter list **at
the export** and §4 says the accepted export forms are part of the contract — so a minifier that
rewrites `export function f(a, b)` into a different form breaks check 4. Two ways out: **(a) a
platform-build job**, the platform ships its siblings already minified and the checks run against
what it shipped, which keeps the compiler out of it and is consistent with rule 6; or **(b) a
compiler job** run *after* the four checks pass, on the copy being written, never on the copy being
read. (a) is simpler; (b) is what gets `core/`'s own siblings, which the platform does not own. Either
way it collides with W2: a minified `core/` makes a defect report point into text nobody can read.

**O3 — source maps.** `--source-maps` is refused today and debugging emitted JavaScript in browser
devtools without them is poor. Nothing in this plan blocks it, and R1's template lowering must not
foreclose them either — a hole's update code has a source position, and `backend.md` §11 should say
so while it is being written rather than after.

---

## 4. What changes elsewhere

> **Revision 3:** the rows for `language.md`, `frontend.md`, `checker.md`, `backend.md` "new §11" and `boundary.md` "new §9" are done, differently: `language.md` §11, `frontend.md` §9, `checker-v2.md` §25, `backend.md` §15 (not §11, which is *Source maps*), `boundary.md` §9. The rest of the table stands.

Owed **once the owner answers**, one line each. Rule 2: no section is renumbered anywhere; every
addition is a new section at the end of its document or a row in an existing table.

| File | Section | Edit |
|---|---|---|
| `language.md` | §0, §3 | `Element` joins `Atom`'s alternatives, with the `Element`/`TagName`/`Attr`/`Child` productions and *"an element is an operand, never a bare argument"* (W30, W31) |
| `language.md` | §6 | **Two additions.** A new subsection beside *Evaluation order* carrying R28 §11.1's twenty rules plus attribute and child evaluation order (left to right in source order, which is §6's existing application row). And **the identity promise** (W27) |
| `language.md` | §9 | Element formatting: attribute break-all, children, self-closing normalisation (W41), closing-tag alignment, and the never-join-lines rule applied |
| `language.md` | §10 | New codes **appended, never inserted**: `unclosed_element`, `mismatched_closing_tag`, `child_not_renderable`, `duplicate_attribute`, `element_as_argument`, `component_children_arity`, `void_element_with_children`, `unkeyed_list_hole` (a warning, root package only) |
| `frontend.md` | §1.2, §3.5 | `dump --stage=ast` gains the element node tags; the new `Ast.Node.Tag` members named |
| `frontend.md` | **new §9** | *Elements in the front end*: the parser's element production, the two recovery cases, keyword attribute names, the quoted-name rule, and the statement that **no lexer mode is added** and why |
| `checker.md` | §6.1, §6.4, §8 | The `renderable` obligation beside `equatable`/`interpolatable`/`tuple_index`, its discharge arm, and `child_not_renderable`'s message shape (L2) |
| `backend.md` | **new §11** | *Compiled templates*: the recogniser and its predicate, the template and hole representation, hole kinds and their update code, the keyed list hole, **the fallback (W29)**, the template-id derivation rule (module index + instruction index, never a shared counter), the path-overflow rule if a packed path is used, source positions for O3, and the `--release` gate |
| `backend.md` | §4 | The parked *"pending M3c's benchmark of a vector trie"* is discharged by R29 §10 and replaced with C1's answer (W35) |
| `backend.md` | §10 | The degenerate single-file case gains R26 §8.2's latency number and moves ahead of chunking (W13) |
| `backend.md` | §9 | If W14 is yes, a sentence on sibling minification and where it sits relative to `boundary.md` §4's checks |
| `boundary.md` | **new §9** | *The markup interface*: a platform may declare an element namespace and a fixed list of well-known runtime names for template lowering, checked the way §4's check 4 is checked — by counting what is declared, never by parsing JavaScript; a platform that declares none gets the plain-call lowering and a working program; the render-to-string platform is the second implementation (W37, W38) |
| `boundary.md` | §4 | A rule for a `foreign` that receives a beni function and calls it back: that parameter must be declared `sync` (W8) |
| `boundary.md` | §5, §5.3, §5.4 | `main`'s browser meaning (W9); the *"Browser: The Elm Architecture"* entry gains the command shape, the renderer and the defect behaviour; §5.4 rewritten — `perform`/`performKeyed`, keys `compare`-able not "equatable", `Cmd.map` pushes a key-path segment, the "Open" paragraph closed (W25, W7) |
| `boundary.md` | §7.1 | *"roughly 45 %"* corrected: **71.9–75.9 %** of a small Elm program is hand-written runtime, the user's own code under 1 % |
| `boundary.md` | §8 | Milestone **B4** expands into B0–B9; the L, R and C tracks are added as prerequisites that need no effects work |
| `transparent-effects-proposal.md` | §6.6 | Replaced by a pointer to this plan's §1 (W25) |
| `transparent-effects-proposal.md` | §7.5 | The microtask tier is **withdrawn**; one tier, a macrotask every slice; the 64 becomes a slice in milliseconds in the scheduler slot (W3) |
| `plans/effects-spike.md` | §1.3, §0.3, S5, S11 | TEA out-of-scope reversed; the kernel platform-neutral with the browser first; E-M10's browser half done except for B4's re-take |
| `plans/effects-decisions.md` | A1, A8, B1, **C9** | A browser paragraph each. **C9 changes from "parked" to "closed"** if W26 is (b)/(c): `lazy` has no job under compiled templates (W27) |
| `plans/effects-plan.md` | §2.5 | The one-bool budget for an argument-position demand **stays one** under the recommended W27, because the identity promise is a language guarantee rather than a second demand. It becomes two only if W26 answers (a) |
| `fast-compiler.md` | §13 | The build order: the L, R and C tracks need nothing from effects and can precede the spike; O1 ahead of chunking |
| `plans/queue.md` | rows 51–55, the browser sections | Row 54 becomes the defect screen; 52–53 gain a browser column; the browser-first section gains the L/R/C/X tracks |

---

## 5. Risks and unknowns, ranked

Each is carried from a report's own *could not determine* or from a conflict between two, with the
cheapest experiment that retires it.

1. **Nobody knows what an `Html msg` is at run time, or what the fallback costs.** R28 recommends
   desugaring to ordinary calls and recognising them structurally; R29's prototypes never build a
   tree at all; neither addresses the seam, and §1.1's own view crosses it three times. **This is the
   plan's one unanswered technical question and it gates `backend.md` §11.** *Retirement:* **X1**,
   one prototype page, no compiler change, no answered W required. Until X1 runs, every number in §2
   and §3 describes a program whose whole view is one template.
2. **The prototypes are not a compiler.** R29 §14 says so in terms: they bound what an emitter could
   reach rather than predict it, and the gap is unmeasured. They also ship no element vocabulary, no
   event system beyond one delegated listener, no XSS sanitisation, no rAF batching and no runtime.
   *Retirement:* **R1**'s exit criterion, with the 20 % tolerance §3 states, and B2′'s size
   measurement. Nothing before then may quote a prototype figure as a platform figure.
3. **One engine, one machine, headless, software rasterisation.** Every rendering number is Chrome
   153 `--headless=new` on one Ryzen; totals are roughly 2× the published ones and all of the
   difference is paint (R29 §1.5). Safari and Firefox are entirely unmeasured for rendering, and
   `scheduler.postTask`/`yield` are not in WebKit at all. *Retirement:* R26's POST-back harness — which
   needs no devtools protocol, which is how its Firefox columns exist — run on any machine with
   Safari, plus R29's page set driven by WebDriver BiDi.
4. **One headline in R29 did not reproduce.** The manager's re-run reproduces the ranking and the
   per-operation script medians to ~10 %, and **not** the claim that the field-directed prototype
   reaches hand-written vanilla's script cost — a geometric mean of ratios dominated by
   sub-millisecond operations, with a noise floor of about ±0.25. *Retirement:* none needed; the rule
   is procedural, and §3's R1 exit criterion states it: judge on per-operation medians, re-run every
   subject in the same batch, never quote the ratio-of-ratios.
5. **Why Svelte 5 replaced compile-time invalidation with signals is unknown**, and Svelte 3/4 shipped
   R3's rung 3 at scale for six years before replacing it. If the reasons are fundamental to
   compiler-derived dependency graphs they kill R3; if they are Svelte-specific they do not transfer.
   R28 and R29 did not chase it. *Retirement:* **X3**, half a day of primary-source reading, **before
   R3 is specified** — and note it does **not** gate R1, which is another reason the two rungs are
   separate slices.
6. **A wide model record falls off V8's fast object-clone cliff.** 29.9 ns at 17 fields, **222.6 ns at
   18**, 986 ns at 64, and a real TEA `Model` has 20–40 fields (R27 §5.6). It is 0.0025 % of a frame,
   so it is guidance rather than a defect — but nobody has measured whether a **nested** model's two
   small clones plus the extra hole indirection actually beat one wide clone in a real view.
   *Retirement:* fold it into **X1**, which is already building three view shapes.
7. **`f a <b` is a legal comparison today, so an element may never be a bare application argument.**
   This is forced rather than risky (R28 §3.4), and the residual risk is a *diagnostic* one: the
   shapes argument position can still parse are a vanishingly small set, but `<-div>` will say *"`<-`
   is only legal in a `let` binding"* rather than *"I expected a tag name"* unless the message
   special-cases it (R28 §3.5). *Retirement:* a `check/bad` fixture per confusable spelling in L1.
8. **No real beni fiber has ever been measured in a browser.** Every R26 scheduler figure comes from
   a 40-line micro-kernel with a 465 ns stand-in work unit. *Retirement:* **B4**, whose exit criterion
   is "re-take R26's table".
9. **Whether a 1 ms slice survives a real page.** Every R26 measurement is a blank page with one
   fiber; a page with a hole pass, CSS animations and a compositor may not give the thread back at
   the same cadence. *Retirement:* B5's typeahead fixture with the input histogram switched on.
10. **The compile-time cost of the field analysis is unmeasured**, because there is no implementation
    (R29 §14). A walk over one function body against a >250k LOC/s budget should be noise; that is an
    expectation. *Retirement:* R3 publishes the number, and `bench` gains a markup-heavy corpus in L1
    so there is something to measure it on — R28 §15 records that none exists today.
11. **Which array shape `core/` should ship** is unmeasured: a 32-way trie loses to a plain
    copy-on-write array for `Append`, `Remove` and a full walk (R29 §10.4). *Retirement:* **X2**.
12. **The loading numbers are HTTP/1.1.** Over HTTP/2 the `modulepreload` row improves and the bundle
    row does not, so 3.0× is an upper bound on the *gap*. *Retirement:* one HTTP/2 server in R26's
    `e8-load.mjs`; it changes O1's justification only in degree.
13. **Hydration was never tested against real server-rendered markup**, and R27 §6.8 adds two costs
    nobody had priced: Solid's hydration is **+1 439 brotli bytes, +28 %** over its CSR runtime, and
    its `isHydrating` check is an unconditional early return at **every attribute write site**, so a
    CSR-only app pays it forever. *Retirement:* none needed until W22 is asked; the insurance is to
    keep the two builds separable in R1's design and to never put a hydration check on the write path.
14. **Clipboard and fullscreen activation gating** could not be measured headless, so the platform
    must not make a claim about them.

---

## 6. A proposed sequence across the whole project

> **SUPERSEDED 2026-09-29 for its phases 1–2** (L1, R1, L2, R2, B2′, B3): the markup order is §7. O1, the experiments X2/X3, B0 and the effects rows stand.

*Given browser-first, and with implementation parked until the owner says otherwise. This is a
recommendation; the owner decides.*

| Phase | Work | Depends on | Why here |
|---|---|---|---|
| **0** | **O1 — the single-file `--release` bundle** | nothing | Unblocked by every open decision; lands on `master`; the largest measured payoff per unit of work anywhere in this plan |
| **0** | **X1 — the fallback-tree experiment** | nothing | Retires the design's one open technical question, for about one prototype page of work, and it is docs/research so it does not compete for the one-builder-at-a-time constraint |
| **0** | Answer `plans/browser-decisions.md` tier 1 | — | Nothing in L, R or B2′ can be specified without W26, W27, W29 and W30–W33 |
| **0** | **B0 — the browser corpus kind** | Chrome | The asset every later browser slice needs; +1.2 % of the gate |
| **1** | **L1 — JSX as sugar**, with the render-to-string platform | W30–W32, W38 | The feature the owner asked for, at its smallest, with the `emit/` golden that makes it a spelling rather than a second language. It also builds the platform every later view test needs |
| **1** | **X2, X3** | nothing | Half a day each; X2 gates C1 and X3 gates R3 |
| **1** | **B1** — the platform skeleton and a static render | B0 | Proves the artifact shape needs no compiler change |
| **2** | **L3 + R1** — the identity promise, then the template recogniser | X1, L1, W26, W27 | L3 first, because R1 is unsound without it. R1 is where the owner's speed requirement is met or missed |
| **2** | **L2 + R2 + C1** — typed holes, the keyed list hole, `core/Array` | R1, X2 | Everything a real view needs; none of it touches effects |
| **2** | **B2′ + B3** — the renderer in a page, the TEA loop | R1, B1 | **The first point at which someone can write a beni application**, and it is reached with no effects work at all |
| **3** | Effects **S0 + S1** — baselines, and the kernel probe | M4-3 (landed) | Still the riskiest unknown in the project: if compiled closure-CPS does not beat 82 ns/op the whole lowering reopens |
| **3** | Effects **S2 + S3** — the two bits, then `sync` | S1 | Where `sync` stops being vacuous; the L and R signatures gain the keyword |
| **4** | Effects **S4–S11**, then **B4 + B5** | S3 | The kernel in a page, then commands and the architecture proof |
| **4** | **R3** — the field analysis | X3, R1 | Deliberately last in the rendering track: it is worth 0.15 of a geometric mean, it is *slower* on a page where each hole has its own field, and X3 might kill it |
| **5** | **B6–B9**, effects **S12–S15**, **O2 + O3** | B5 | Subscriptions, navigation, ports, the defect screen; sibling minification and source maps |
| **6** | **M4-4, M4-5** (the daemon), chunking | — | The daemon makes the compiler fast to *use*; it has been overtaken by browser-first and should be said so out loud |

**The recommended first un-parked implementation slice: still O1, the single-file `--release`
bundle** — and the argument is re-made from scratch rather than carried over, because everything else
in the plan moved.

1. **It is unblocked by every question on the decision sheet**, including the eleven new ones. It
   needs no W answer, no effects slice, no platform, no new corpus kind, and no experiment.
2. **Its payoff is the largest measured one in the plan and it got larger.** 358 ms to `main` against
   1 059 ms on 4G, 3.0× (R26 §8.2), for a change `backend.md` §10 has already specified down to its
   acceptance criteria — and R29 §12.2 now shows the same module-graph tax from another angle, 19.8 ms
   of resource time against 2.4 even on localhost where there is no round trip worth the name.
3. **It makes every later size measurement real.** W11's budget, B1's floor, B2′'s counter and §2.6's
   whole decomposition are judged on what a browser actually downloads, and today that is thirteen
   unminified files.
4. **It lands on `master`, not on a branch**, so it does not compete with anything for the
   one-builder-at-a-time constraint and it cannot be stranded by a decision.

**What changed in the argument.** Revision 1's runner-up was B0. It is now **X1**, and the honest case
for X1 going first instead is that O1 is a *known* win of known size while X1 is the thing standing
between the project and a specification it cannot write. **The tie-breaker is that they do not
compete**: X1 is scratchpad research with no repository output, so it can run beside O1 rather than
instead of it, exactly as the three reports ran beside M4. Recommend both, with X1's deliverable due
before `backend.md` §11 is drafted.

**Why L1 is not first**, even though JSX is what the owner asked for. It needs a specification pass
before a line of Zig (rule 1: `language.md` §3, §6, §9, §10 and `frontend.md`'s new §9), it needs
W30, W31 and W32 answered, and it needs a render-to-string platform to satisfy rule 3 at all. That is
a genuine week of docs plus three owner answers, and none of it is blocked by O1 running first. **If
the owner would rather see the feature than the bundle, the honest reordering is: answer W30–W32,
write the `language.md` and `frontend.md` sections, and start L1** — and O1 then slips rather than
disappears, because they touch different files.

**What should *not* be first: the effects spike.** Not because it is less valuable — S1's question is
the riskiest in the project — but because §3 has just established that the language track, the
rendering track, `core/Array` and the first three browser slices need **nothing** from it. Effects
gates commands, subscriptions and the defect screen, and nothing else. It should start when its
remaining tier-A answers are in and browser-first has been folded into S5 and S11, which is one docs
pass away.

---

## 7. The markup slice plan (revision 3.1, 2026-09-29)

Research 36 §7's J0–J8 (that report's own ids), adapted to the owner's *JSX targets* answer: the
compiler builds **one lowering interface** and the platforms build the lowerings on it, so the `ssr`
and `dom` slices are platform work in `platforms/node/` and `platforms/browser/`, and the interface
slice comes before either. Each slice is specified already (MJ0), lands whole with the three gates
green, and gets hand-picked tests: the smallest fixture that reaches each new branch, never a sweep
(the matrix was deleted for that reason, `fast-compiler.md` §8). Line counts are research 36's,
re-cut. *Revision 3.1* renamed the slices (they were J0–J9), moved markup's BIR into MJ2, where no
slice held it, and added the review's work to each slice.

**Nothing here needs the effects work** (§3, *What needs effects*): until `sync` exists every
handler is vacuously `sync`, and `preventDefault` is a declaration fact (MD12). `Browser.flush` and
after-render capabilities are the two pieces of MJ8's loop that wait on effects (MD36).

| # | Slice | Builds | Size | Tests that prove it |
|---|---|---|---|---|
| **MJ0** | **Specification** | `language.md` §11, `frontend.md` §9, `checker-v2.md` §25, `boundary.md` §9, `backend.md` §15, this block; revised after the review | docs | reviewed against research 36 §2's examples and the owner's answers, including the spec review's |
| **MJ1** | **Lexer modes** | the mode stack, eight token kinds, the operand-start rule, the column-1 reset, the depth bound, the three stray bytes in text, a spread after whitespace, a stray byte in a tag; front-end artifact v5 (`frontend.md` §9.1–§9.3); `bench/markup/` and the bench harness's `--phases` | 350–450 | `parse/` token dumps: `a <b`, `f a <b`, `(<)`, `x = <b />`, `[ <li />, <li /> ]`, text holding `--`, `'` and `"`, text holding `a < b` (one `invalid`, the text resuming), `>` and `}` in text, `{ ...x }` and `{` then `...` on the next line, `...` later in a hole (not an `ellipsis`), a string inside a hole, `${…}` holding `<`, `{-- note}` (the `}` inside the comment), a stray `<` inside a tag, a column-1 declaration after an unclosed element, the 4 096 bound; `--roundtrip-frontend` over a markup file; **`zig build bench` unchanged on the markup-free corpus**, and `zig build bench -- --corpus=bench/markup --phases=lex` recorded in the commit |
| **MJ2** | **Parser, AST, recovery, formatter, BIR, dump** | `frontend.md` §9.4–§9.7; `language.md` §11.3–§11.5, §11.15; the character-reference table and decoder (`src/markup/entities.zig`); markup trees, constants, entries, rows with captures and inputs, lowering's diagnostics | 1 400–1 800 | `parse/good` AST goldens per production (element, fragment, `For`, `Show`, attribute forms, spread, holes, the four vocabulary declarations); `parse/bad` for `unclosed_element`, `mismatched_closing_tag` (one message), `element_as_argument`, `>` in text, `<-div>`, `{-- note}` (the message naming the comment); `fmt/` goldens where whitespace must not move — children on one line past 100 columns, a space between two elements, two spaces between words, a no-break space — plus `<div></div>` → `<div />` and a comment hole; idempotence over all of them; `bir/` goldens for trimmed and decoded text (`&nbsp;` kept, a typed U+00A0 collapsed, `&notit;`, `&#x80;`), a decoded quoted attribute and an undecoded `{"&amp;"}`, entries, and the three row shapes with inputs through a same-module helper; the decoder's hermetic tests are `htmlize` 1.1.0's vectors; `check/bad` (lowering's codes) for `duplicate_attribute`, `spread_on_element`, `spread_not_first`, `invalid_form_children`, `unknown_form_attribute` (`key=`), `missing_form_attribute` (`For` without `each`, `Show` without `keyed`), `invalid_keyed` (`keyed="x"`, `Show keyed={False}`) and `vocabulary_outside_platform`; `bench -- --corpus=bench/markup --phases=lex,parse` |
| **MJ3** | **Layered platforms and vocabularies** | `"platforms"`, `"reexports"`, the chain's enumeration and output under `_platform/_<name>/`, inherited output keys and `markup` fields (`boundary.md` §9.1–§9.2); the four declarations through lowering, and their interface tables (iface v8); the `markup` key's validation; the `html` platform (vocabulary, primitives `text` and `map`, no program), and `node` depending on it and re-exporting `Html`; the vocabulary module's own markup, with no edge to itself | 450–650 | **every `run/` program's emitted bytes unchanged** (the run-hash file does not move); `check/good` `.iface` of a vocabulary module; `build/bad` for a platform cycle, `unknown_markup_lowering` (a name the binary lacks, and a surviving root under a chain that names none), `vocabulary_outside_platform`, an app importing a module no platform re-exports (the message names the key), `build --platform=html` without `--library` (exit 2, "only depended on"), a `lowering` and a `runtime` from different packages; `check --platform=html` of a view module; a vocabulary module whose own `view` writes markup, and one whose import writes markup (`import_cycle`, naming the markup edge); a two-layer test platform under `tests/` whose top declares nothing and inherits `program` |
| **MJ4** | **Checker** | resolution against the vocabulary, the four obligations, `For`'s and `Show`'s checks, components as calls, the list forms, primitives, `markup_type_in_foreign`, the warnings, the markup section of the dispatch table (`checker-v2.md` §25) | 800–1 100 + 200–300 of diagnostics | a `check/bad` fixture per code of §25.9; `check/good` for research 28 §11.2's typeahead in bare-text form — **no conversion written anywhere** — with its `dispatch/` golden showing hole kinds, handler forms, list forms and row arities; `class` given a `String`, a list literal and a list variable; a row given as `{viewRow}`, `{viewRow model _}` and a two-parameter lambda; `Show` by identity and by key, with `key_not_primitive` on a record key; `markup_type_in_foreign` in `html` and a legal one in `node`; `ordering_test.zig` permutations of a module whose component and `view` are in both orders; `cache_test.zig`: editing a vocabulary declaration re-checks the markup-using modules and nothing else, editing only a `view`'s markup moves no interface hash |
| **MJ5** | **The lowering interface, and `ssr`** | `src/markup/Interface.zig` at version 1.0 (`boundary.md` §9.4.2–§9.4.3), the `"zig"` key, the registry `build.zig` generates, `-Dplatform=<dir>` and `beni.addPlatform`, the runtime-export checks over the union of the lowering's exports, the primitives and `run` (`boundary.md` §9.4–§9.6); the `comptime` version check and `Tree.requires`; BIR → tree; the values prelude; `platforms/node/zig/ssr.zig` and the Node markup runtime with `text`, `map`, `classes` and `styles`; the HTML parser table in `html`'s Zig | 900–1 200 + ~60 JS | **the first slice that runs markup.** `run/`: text (collapsing over the Unicode set, every reference kind) and attribute escaping (`&`, `<`, `"`, a script URL), every attribute value class including both list forms and their in-place split, `For` in its three modes and `fallback`, `Show` by identity, by key and with a fallback, components with every `children` form and a leading spread, fragments, `Html.text`, nested `Html.map` (identity under `ssr`), blocks from a helper, a `let` and a `case`, a `script` element's raw text, a view formatted and re-rendered to the same string; `build/bad` for a runtime missing a well-known export, one missing a primitive, one with the wrong arity, and a primitive named like an export; **the identity pair** — `emit/` and `emit/release/` goldens of a record update, and a `run/` fixture over a test platform's `refEq`; the determinism scenarios with a markup program in; **one `build.zig` step that builds beni with a toy external lowering from `tests/platforms/` targeting 1.0 and runs one fixture through it** |
| **B0** | **The browser corpus kind** (§3, unchanged) | one long-lived headless Chrome, a target per fixture, virtual time | harness | ≤ +2 % of `test-blackbox`; loud skip with no Chrome |
| **MJ6** | **The `dom` lowering and the `browser` runtime** | `platforms/browser/zig/dom.zig`: templates with re-encoded text, walks, markers, `m`/`p` as statements, blocks and the three slot exports, component slots, the list forms, events, the mount context and `map`, and the start data (`backend.md` §15.1–§15.4); `platforms/browser/runtime.js`, program and markup runtime in one file (~350 lines, from research 36 §4.7's runtime) | 1 400–1 800 + ~350 JS | `emit/` goldens for research 36 §2.1–§2.11's shapes, a class list split in place, and a `p` written as `if`s; one `emit/release/` golden with walks inlined; **the differential oracle** (`backend.md` §15.10) — the sixteen `__dom_fixtures__` in beni, template strings and walks against the checked-in extraction of Solid's `output.js`, with the listed differences; `markup_restructured` for `<p><div>`, for a vocabulary that says `br` is not void, and for a `style` whose text holds `</style`; `browser/`: a delegated `click` listens once for a thousand rows, a branch swap does not carry an `<input>`'s value across, a controlled input reverts a rejected edit, a message from inside two `Html.map`s arrives mapped innermost first, a class list toggles one class and leaves the template's, a `--library` build still delivers events |
| **MJ7** | **`For` and `Show` in a page** | `forKeyed`, `forPosition`, reference keying, duplicate keys, row inputs, `show`/`hide` (`backend.md` §15.5) | 350–450 | `browser/`: a keyed reorder keeps a focused input in its row and a positional one does not (the warning's point); duplicate keys render every item; update-every-10th keeps the same `<tr>` nodes; swap moves the same nodes; an edit to an unrelated model field calls no row function (the inputs' point, counted by an instrumented row); a keyed `Show` remounts on a new value, patches on the same one and, by key, patches across an edit of the shown record |
| **MJ8** | **`browser` and `browser-tea`** | `browser`'s low-level `Program`, `run`, mount and `$$root`; the render loop of `backend.md` §15.11 — one microtask flush, patch then after-render work, the runtime's `flush`; `browser-tea` in beni over it, `Html.map` for nested `Msg` | 300–500 beni + ~120 JS | `browser/`: five messages in one task render once, the runtime's `flush` renders now (driven by the harness, since `Browser.flush` arrives with effects), a message sent from after-render work renders in the next flush, two programs on one page each receive their own messages, a controlled input is reconciled before the next keystroke; a DOM-free `run/` fixture drives the TEA loop through `ssr`; the empty mounted page's bytes, dev and `--release`, into `bench/size.mjs` (W11's first half) |
| **MJ9** | **End to end against Solid 2** | research 29's benchmark app in beni markup, compiled by beni | — | research 29's harness with **Solid 2.0.0-rc.9 re-run in the same batch**; the per-operation script medians of R1's table above, beaten per operation and allowed 20 % over the hand-written P2; research 29's static-heavy page; **a helper-heavy page** (research 36 question 3), which decides MD18; the row written idiomatically as `rowClass model row` (MD31); size against Solid 2's 22 163 brotli. Never a geometric mean |
| later | hydration (an `ssr`/`dom` pairing); `ref` as an element handle delivered in a message (question 6, W44); portals; spread of known attributes and a tag chosen at run time (MD10); more direct consumers (MD18, if MJ9 says so); P3's selector recognition, rung 4 (research 29 §7.2, after X3); `sync` handlers that call `preventDefault` themselves, `Browser.flush` and after-render capabilities, once effects land (W34, MD36); typed content categories; the first gated feature of interface 1.1, with `markup_feature_unsupported` (MD32) | | | |

**Order and why.** MJ1–MJ4 are the front end and checker and need no platform code beyond MJ3's
vocabulary. **MJ5 before MJ6**, deliberately, as research 36 §7 argued: `ssr` exercises the whole
front end, the interface and the vocabulary seam with a runtime of sixty lines, and gives rule 3 its
`run/` coverage before any browser exists — and building the interface against the *simpler* lowering
first is what keeps it from being `dom`'s API wearing a hat. B0 is needed from MJ6's `browser/` tests
on and can land any time before. MJ9 is last because it measures what MJ5–MJ8 built.

*Built, 2026-09-29:* the lowering interface and the `ssr` lowering, as the *As built* notes of
`boundary.md` §9.3, §9.4 and §9.5 and `backend.md` §15.6 record — including what they changed:
`Ssr.render` in place of `Node.render`, `list`'s third argument, `rawText`, and the extractor's
reachability leg left to the first lowering that reads an extractor.

*Built, 2026-09-29:* MJ6 and MJ7 whole, and MJ8's `browser` half — the `browser` platform
(`Browser.program`, `run` at `document.body`, `$$root`), the `dom` lowering and its one runtime file,
`For` in all three modes with duplicate keys and row inputs, keyed `Show`, the microtask render loop
and `flush` — with the extractor's reachability leg, as `backend.md` §15's *As built* note records,
including where it departs: rows made where their list is evaluated, `forKeyed`'s last argument the
inputs, four more runtime exports, names all by site, and a render after every message. Not built:
`browser-tea`, the after-render queue (it waits on effects), two programs on one page (one mount
point until W9), and the empty page's bytes in `bench/size.mjs`. The differential oracle is
`tests/oracle/`, its sixteen fixtures' differences listed with their reasons.

*Built, 2026-09-29:* the rest of MJ8 that needs no effects — `browser-tea` (`Tea.sandbox`, beni over
`Browser.program`, no JavaScript), its pages (nested `Html.map`, five messages rendering once,
`flush`, a controlled input reconciled before the next keystroke through the driver's new `type`
step), the DOM-free `run/TeaLoop`, and the empty mounted page in `bench/size.mjs` (`browser` 6 251
brotli, 6 178 released) — as `boundary.md` §9.1's and `backend.md` §15.11's *As built* notes for
`browser-tea` record, including where they depart: `sandbox` rather than `element` until commands
and subscriptions exist, `reexports` without the `Browser.Dom` that does not exist, and a `run/`
loop written in the fixture because `Tea` cannot build under `ssr`. Still not built: two programs
on one page (W9 did not settle where a program mounts), and the after-render queue with the
message sent from it (effects).

*Built, 2026-09-29:* two programs on one page, once `plans/browser-decisions.md` settled where a
program mounts — `Browser.mountAt` and `Browser.programs`, the handler's program searched from its
node's parent, the delegated walk no longer stopping at the first mount node
(`backend.md` §15.11) — with `tests/corpus/browser/tea/TwoPrograms`; and `Tea.Program`, now that
`main`'s annotation is compared through aliases (`boundary.md` §5, `run/MainTypeAlias`). MJ8 now
owes only the after-render queue, which waits on effects.

*Measured, 2026-09-29 (MJ9):* [research 39](../docs/design/research/39-beni-markup-against-solid-2.md),
with the harness rebuilt in `bench/ui/` (research 29's did not survive). Script medians against
Solid 2.0.0-rc.9 in the same batch: beni wins seven of nine (create 1k 0.82×, replace 0.84×, update
every 10th 0.67×, select 0.88×, create 10k 0.80×, append 0.85×, clear 0.89×), ties swap (1.03×,
ranges overlapping) and loses remove (1.09×); `--release` is the same. Within 20 % of the
hand-written P2 only on replace (1.11×) and clear (1.01×) — the bar is **not met** on seven.
Two runtime fixes landed with it (a keyed list patched in place while its keys keep their order;
a list that is all its parent holds cleared at once). Priced but not built: `==` against a
constructor as a tag test plus handler holes not rebuilt on an input-only patch (select → 1.02×
P2), and the key map kept across a render that moves rows (swap → 0.82× Solid 2, remove → 1.01×);
the rest of swap and remove is the model half on `List`. **MD18: the helper-heavy page loses to
Solid 2 by 4.5× per message** (30 µs against 6.8; one `view` is 4.3, one component per section
7.0), so more direct consumers do pay — research 39 §6.3 and §7 recommend skipping a helper call
in a hole whose arguments are identical. Size: 11 697 brotli released (5 739 minified) against
Solid 2's 22 131.

**Is MJ1 fully specified?** Yes, after revision 3.1: every byte the lexer can meet in each of its
modes has a token or a stated error — the three stray bytes in text, a stray byte in a tag, a spread
after whitespace, `...` elsewhere, and a comment that swallows a hole's `}`, which the lexer lexes as
it lexes any comment and the parser explains (`frontend.md` §9.1). Its measurement no longer depends
on `bench/corpus/` building markup (`frontend.md` §9.3).

**Total**: about 5 350–7 350 lines of Zig and ~530 of JavaScript, research 36's estimate plus the
interface, the layering, markup's BIR and the review's additions, which it did not have.
