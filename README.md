# Beni

Beni is a statically typed functional language in the ML family that compiles
to JavaScript.

- **Fast compiler**: 768K lines/s on one core, 6× faster than TypeScript 7.
- **No runtime errors**: no `null`, no `undefined`, no exceptions.
- **Hindley–Milner type inference**: annotations are optional.
- **Colorless functions**: no `async` or `await`; the runtime handles waiting.
- **Fast UI**: compiled templates, as fast as Solid, 1.4 kB for an empty page.

```elm
type Shape
    = Circle Float
    | Rect Float Float


area : Shape → Float
area shape =
    case shape of
        Circle r →
            pi * r * r

        Rect w h →
            w * h


largest : List Shape, Int → List (Shape × Float)
largest shapes n =
    shapes
        ▷ List.map λs → ( s, area s )
        ▷ List.filter λ( _, a ) → a ≥ 1.0
        ▷ List.sortBy λ( _, a ) → -a
        ▷ List.take n
```

## The language

Beni has custom types and records, pattern matching with exhaustiveness
checking, and type inference throughout. Values are immutable and functions are
pure. A missing value is a `Maybe` and a failure is a `Result`, and the type
checker proves that every `case` handles every value.

Functions take all their arguments at once. A call is never partially applied by
accident, and when you do want partial application you write it, as in
`List.map xs (scale 2 _)`. A type's functions can be called as methods
(`point.distance other`), resolved at compile time, and a function can require
them of its argument (`where a.compare : a, a → Order`).

Effects need no special syntax. The compiler infers which functions may wait, on
a timer or on the network, and the runtime handles the rest, including
cancellation, timeouts, retries and structured concurrency:

```elm
search : String, Cmd.Send Msg → ⊤
search q send =
    Time.sleep (Time.millis 250)
    send (Found (lookup q))
```

`schema` declarations describe data coming from outside, such as JSON over
HTTP, and compile to their own parsers and printers with typed errors.

## Platforms

The language knows nothing about the browser or Node. A platform package
supplies what a program can do on a host: its `main`, its effects and its
bindings to JavaScript. Every line of JavaScript in a build lives in the
platform, written to report each documented failure as a typed value, so
libraries are pure Beni and cannot break the guarantees.

Beni ships with these platforms:

- **`node`**: programs and tests run under Node.
- **`browser`**: the DOM, events, HTTP, storage, routing and timers.
- **`browser-tea`**: The Elm Architecture on top of `browser`, with commands,
  subscriptions and keyed, cancellable effects.
- **`html`**: the shared HTML vocabulary, so one view can render in the
  browser or to a string under Node.

Markup is part of the language, written as JSX and typed against the
platform's vocabulary:

```elm
import Html exposing (Html)
import Tea


type Msg
    = Increment
    | Decrement


update : Msg, Int → Int
update msg count =
    case msg of
        Increment →
            count + 1

        Decrement →
            count - 1


view : Int → Html Msg
view count =
    <div>
        <button onClick={Decrement}>-</button>
        <span>{count}</span>
        <button onClick={Increment}>+</button>
    </div>


main : Tea.Program
main = Tea.sandbox { init = 0, update = update, view = view }
```

The `browser` platform compiles a view into HTML templates that are cloned once
and then patched only where a value changed. On js-framework-benchmark's
operations its script time beats Solid 1 on eight of nine in our harness.

## The compiler

The compiler is written in Zig, with flat data-oriented IRs, files checked in
parallel and an on-disk cache keyed by content. A 100 000-line project checks
cold in under 40 ms on eight threads, and in about 0.13 s on one.

## Inspirations

Beni starts from Elm, which gave it The Elm Architecture, its guarantees and
its style of error messages. Other ideas come from:

- **Roc**: platforms that own all host code, and methods resolved at compile
  time.
- **Solid** and **dom-expressions**: the template compiler and the render loop.
- **Effect**: the fiber runtime and the schema library.
- **Zig**: the data-oriented design of the compiler.

Coming from Elm, you will notice that functions are not curried, lambdas are
written `λx → …`, lists are matched with brackets (`[ x, …rest ]`), the pipe is
`▷`, tuple types are `Int × String`, markup is JSX, effects are inferred, and
methods and `schema` declarations exist.

## Status

Beni is pre-1.0 and changes often. The compiler, the type checker, the
JavaScript backend, the platforms above, effects, routing, HTTP and schemas are
built and tested. Packages, editor support and user documentation are not built
yet.

## Try it

The toolchain (Zig 0.17 and Node 24) is pinned by `flake.nix`. Run
`direnv allow` to put it on your `PATH`.

```sh
zig build
./zig-out/bin/beni new --platform=browser-tea hello
./zig-out/bin/beni serve hello
```

`serve` rebuilds and reloads the page on every save.

## Learn more

Each part of Beni is specified before it is built, and the specification is
normative. Start with [`docs/design/language.md`](docs/design/language.md); the
rest is in [`docs/design/`](docs/design/). Contributors should read
[`CLAUDE.md`](CLAUDE.md) for the build, the test gates and the project rules.
