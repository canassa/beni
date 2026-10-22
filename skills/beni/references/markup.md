# Markup

Markup is JSX in the language: `<div class="a">{name}</div>` is an expression of the platform's
markup type, `Html msg`. The vocabulary — which elements, attributes and events exist — comes
from the `html` platform (`api-html.md` lists all of it); the language knows none of it.

## Elements and attributes

- A lower-case tag is an element: `<div>`, `<input />`, `<my-widget>`. A closing tag repeats the
  name (`mismatched_closing_tag` otherwise). `<p></p>` and `<p />` are the same.
- `name="text"` is a string attribute. `name={expr}` is any typed value. A bare `name` is
  `name={True}`. Character references in text and quoted values are decoded.
- Markup starts only where an operand starts: after `=`, `→`, `(`, `,`, in a hole, as an argument
  in parentheses.
- A child is text, a hole `{expr}`, or more markup. A hole holds a `String`, `Int`, `Float`,
  `Bool` or `Char` (rendered as text), an `Html msg`, a `Maybe (Html msg)` or a `List (Html msg)`
  (matched by position). Anything else is `child_not_renderable`. `if` and `case` are expressions,
  so they work in a hole; there is no non-keyed `Show`. A `{}` that holds only a `--` comment renders
  nothing.
- `<>…</>` is a fragment.
- `class={[ ( "row", True ), ( "danger", isLate ) ]}` is a class list; `style={[ ( "--gap", "4px" ) ]}`
  a style list. A plain `String` works on both.

```beni platform=html
import Html exposing (Html)


pub type alias Row =
    label : String
    late : Bool


pub view : List Row → Html msg
view rows =
    <table class="rows">
        <For each={rows} keyed={.label}>
            {λrow → <tr class={[ ( "row", True ), ( "late", row.late ) ]}><td>{row.label}</td></tr>}
        </For>
    </table>
```

## Events

An event attribute takes a **handler**: a message, or a function from the event's payload to a
message. Which one is decided by the handler's type.

- `onClick={Clicked}` sends `Clicked`.
- `onInput={Typed}` calls `Typed` with the input's value, a `String`, and sends the result.
- A handler receives the raw `Html.Event` where the vocabulary says so (`onKeyDown`, `onSubmit`,
  `onClick` through a lambda). It can call `Html.preventDefault event` itself, as a statement,
  then return the message. `Html.key event`, `Html.targetValue event` and `Html.targetChecked event`
  read it.
- A handler must not wait. It returns a message and does nothing else.

```beni platform=html
import Html exposing (Html)


type Msg
    = Typed String
    | Submitted
    | Pressed String


pub form : String → Html Msg
form draft =
    <form onSubmit={λevent → submitted event}>
        <input value={draft} onInput={Typed} onKeyDown={λevent → Pressed (Html.key event)} />
        <button>Add</button>
    </form>


submitted : Html.Event → Msg
submitted event =
    Html.preventDefault event
    Submitted
```

### Pointer input

The mouse, the pen and a touch screen use one set of events: `onPointerDown`, `onPointerMove`,
`onPointerUp`, `onPointerCancel`, `onPointerEnter` and `onPointerLeave`. Each handler gets an
`Html.Pointer`.

- `Html.localX p` and `Html.localY p` are CSS pixels from the top-left corner of the border box of
  the element that has the handler. A child under the pointer does not change this.
- `Html.clientX p` and `Html.clientY p` are the viewport's coordinates.
- `Html.pointerId p` is the same from a pointer's down to its up or cancel; each finger has its
  own. `Html.pointerType p` is `"mouse"`, `"pen"`, `"touch"` or `""`. `Html.isPrimary p` is the
  mouse or the first finger.
- `Html.pointerEvent p` is the same event as an `Html.Event`, for `Html.preventDefault` and the
  modifier keys.
- A `Pointer` stays correct after the dispatch, so a message can carry it into `update`.
- The API lists `Html.pointer`, but only the events call it. A program cannot call it, because its
  parameter type is private to `Html`.
- To stop scroll and zoom under a finger, put `touch-action: none` in the element's `style`.
  `preventDefault` cannot stop them. On iOS, a double-tap still zooms an element with
  `position: absolute` (WebKit bug 218015).
- To stop a long press that selects text, write `user-select: none` and `-webkit-user-select: none`
  (Safari) in the `style`. For iOS, also write `-webkit-touch-callout: none`: it stops the
  long-press menu.
- End a touch on `onPointerCancel` as on `onPointerUp`: the browser cancels a pointer when it
  takes the gesture.

```beni platform=html
import Html exposing (Html)


type Msg
    = Aim Float Float
    | Lift


pub arena : Html Msg
arena =
    <div
        style="position: relative; width: 600px; height: 400px; touch-action: none"
        onPointerDown={aim}
        onPointerMove={aim}
        onPointerUp={λ_ → Lift}
        onPointerCancel={λ_ → Lift}
    />


aim : Html.Pointer → Msg
aim p = Aim (Html.localX p) (Html.localY p)
```

## Components

A capitalised tag names a module, and the component is that module's `view`: `<TodoItem todo={t}
done />` is `TodoItem.view { todo = t, done = True }`. `<Card.header title="x" />` is
`Card.header { title = "x" }`. The module comes from this file's imports.

- The callee takes one record and returns `Html msg`. Each attribute is a field; the record is
  closed.
- `<Card {…Card.defaults} title="x" />` spreads a record first, then overrides fields: optional
  props.
- A module cannot name itself in a tag yet. Inside the module, write the call: `{badge { count = 3 }}`.

## `For` and `Show`

```text
<For each={rows} keyed={.id} fallback={<p>No rows</p>}>
    {λrow → <tr>…</tr>}
</For>

<Show when={model.editing} keyed fallback={<p>Pick one</p>}>
    {λuser → <UserEditor user={user} />}
</Show>
```

- `For` renders a list. `each` is the `List a`; the child is one hole holding the row function,
  `a → Html msg` or `a, Int → Html msg`. `keyed={f}` keeps a row's DOM by key (`f` returns a `String`,
  `Int`, `Float`, `Char` or `Bool`); `keyed={False}` by position; a bare `keyed`, or no `keyed`, by the
  item's identity, which a record update changes. `fallback` shows when the list is empty.
- `Show` renders a `Maybe`. `when : Maybe a`; the child is `a → Html msg`; `keyed` remounts when
  the identity (or the key `keyed={f}`) changes; `fallback` shows on `Nothing`.
- A row function whose body is markup is compiled in place; any other function is called per row.

## `Html.map` and the plain-call form

- `Html.map child Wrap` maps a child's messages: subject first.
- `Html.text s` is a text node as a value.
- Every markup form has a plain-call form with the same type; markup is the one the formatter
  keeps.

## Why a render is cheap

A render clones a template once and patches only the holes whose values changed, by identity. A
record update keeps the identity of every field it does not name, and an unchanged field costs
nothing. Build the model with updates, and keep an untouched list as the same value.

Sources: `docs/design/language.md` §11; `docs/design/boundary.md` §9.8.20; `platforms/html/Html.beni`.
