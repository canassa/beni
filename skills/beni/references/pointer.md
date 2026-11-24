# Pointer input

A page reads the mouse, the pen and a touch through the pointer events, and opens a menu of its own
with `onContextMenu`. These are events of the markup vocabulary (`references/markup.md`, *Events*),
so each platform that renders `Html` in a page has them: `browser`, `browser-tea` and
`browser-inline`.

## Pointer events

The mouse, the pen and a touch screen use one set of events: `onPointerDown`, `onPointerMove`,
`onPointerUp`, `onPointerCancel`, `onPointerEnter` and `onPointerLeave`. Each handler gets an
`Html.Pointer`.

- `Html.localX p` and `Html.localY p` are CSS pixels from the top-left corner of the border box of
  the element that has the handler. A child under the pointer does not change this.
- `Html.clientX p` and `Html.clientY p` are the viewport's coordinates.
- `Html.pointerId p` is the same from a pointer's down to its up or cancel; each finger has its
  own. `Html.pointerType p` is `"mouse"`, `"pen"`, `"touch"` or `""`. `Html.isPrimary p` is the
  mouse or the first finger.
- `Html.button p` is the button whose change made the event: `0` the main button (the left one, a
  touch, a pen on the surface), `1` the middle button, `2` the secondary button (the right one),
  `3` back, `4` forward, `5` a pen's eraser. It is `-1` when no button changed, as on a move.
- `Html.buttons p` is the sum of the buttons that are down: `1` main, `2` secondary, `4` middle,
  `8` back, `16` forward, `32` eraser. It is `0` when none is down. Test one part with `Int32.and`.
- `Html.pointerEvent p` is the same event as an `Html.Event`, for `Html.preventDefault` and the
  modifier keys.
- A `Pointer` stays correct after the dispatch, so a message can carry it into `update`.
- When an element and an element inside it both have a handler for the same pointer event, both
  handlers run for one event, the inner one first, as for `onClick`. On the `browser` and
  `browser-tea` platforms the page renders once after them, so each handler runs with the view that
  was on the page when the event came. `onPointerEnter` and `onPointerLeave` do not bubble: each
  element gets its own enter or leave event, so nested enter or leave handlers render once for each
  element, and an inner handler runs with the view that the outer one's render wrote.
- On the `browser` and `browser-tea` platforms, a pointer handler on a disabled control does not
  run, as an `onClick` there does not.
- The pointer events name their extractor `pointer` (`via pointer`). It is private to `Html`, so
  a program cannot call it.
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

## The context menu

`onContextMenu` is the browser's `contextmenu` event: the user asks for the context menu, with the
right mouse button or with the keyboard's menu key. Its handler gets an `Html.Pointer`, as a
pointer handler does.

- To show a menu of your own, call `Html.preventDefault (Html.pointerEvent p)` in the handler, as a
  statement, then return the message. Without the call, the browser shows its menu too.
- Put the menu at `Html.clientX p` and `Html.clientY p` with `position: fixed`, or at `Html.localX p`
  and `Html.localY p` in the element that has the handler.
- To tell a right-click from a left-click with no menu, read `Html.button p` in `onPointerDown`.
  `preventDefault` on a pointer event does not stop the browser's menu.
- `Html.isPrimary p` is `False` on each `onContextMenu`.
- When the event has no pointer, `Html.pointerId p` is `-1` and `Html.pointerType p` is `""`. A
  browser before Chrome 92, Firefox 129 and Safari 18.2 gives these values for each
  `onContextMenu`. The standard gives them to a menu that the keyboard asks for, but Chrome gives
  such a menu the mouse's pointer, and a `button` of `-1`.
- When an element and an element inside it both have an `onContextMenu`, both handlers run, the
  inner one first. On the `browser` and `browser-tea` platforms, a handler on a disabled control
  does not run.
- The system decides if the event comes when the button goes down or when it comes up.
- Safari on iOS sends no `contextmenu` for a touch. For a long press, use `onPointerDown`,
  `onPointerUp` and a timer.
- In Firefox, a right-click with Shift held shows the browser's menu and sends no event.
- On a prerendered page, a `contextmenu` before the program runs is not recorded.

```beni platform=html
import Html exposing (Html)
import Int32


type Msg
    = Open Int Float Float
    | Select Int
    | Paint Int


pub row : Int → Html Msg
row id =
    <li
        onPointerDown={λp → pressed id p}
        onPointerMove={λp → moved id p}
        onContextMenu={λp → menu id p}
    >
        {id}
    </li>


menu : Int, Html.Pointer → Msg
menu id p =
    Html.preventDefault (Html.pointerEvent p)
    Open id (Html.clientX p) (Html.clientY p)


pressed : Int, Html.Pointer → Msg
pressed id p = if Html.button p == 0 then Select id else Select 0


-- A move with the main button down paints the row.
moved : Int, Html.Pointer → Msg
moved id p =
    down = Int32.and (Int32.fromInt (Html.buttons p)) (Int32.fromInt 1)
    if Int32.toInt down ≠ 0 then Paint id else Paint 0
```

Sources: `docs/design/boundary.md` §9.8.20; `docs/design/prerender.md` §6.5; `docs/design/backend.md` §15.11; `platforms/html/Html.beni`.
