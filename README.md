# Beni

Beni is a statically typed functional language in the ML family that compiles
to JavaScript.

- **Fast compiler**: written in Zig, 768K lines/s on one core, 6× faster than TypeScript 7.
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

### Custom types and pattern matching

A custom type lists every shape a value can take. A `case` must handle all of
them, so adding a new shape later points you at every place that needs to
change.

```elm
type Payment
    = Cash
    | Card String
    | Voucher Int


describe : Payment → String
describe payment =
    case payment of
        Cash →
            "cash"

        Card last4 →
            "card ending in ${last4}"

        Voucher amount →
            "voucher for ${String.fromInt amount}"
```

### Immutable records

Records hold named fields. Updating one gives you a new record and leaves the
old one as it was.

```elm
type alias User =
    name : String
    age : Int


birthday : User → User
birthday user = { user | age = user.age + 1 }
```

### Type inference

Annotations are optional. The compiler infers the most general type, here
`List number → List number`.

```elm
double xs = List.map xs λx → x * 2
```

### No currying

A function takes all its arguments in one call. Partial application is written
out with `_`, so it never happens by accident.

```elm
scale : Float, Float → Float
scale factor x = factor * x


doubled : List Float
doubled = List.map [ 1.0, 2.0, 3.0 ] (scale 2 _)
```

### Static dispatch

Most of what type classes give you, with much less machinery. A module's
functions can be called as methods on its type, so `v.add w` is
`Vec.add v w`, and a `where` clause asks for a method on any type.

```elm
-- Vec.beni
pub type Vec
    = Vec Float Float


pub add : Vec, Vec → Vec
add (Vec a b) (Vec c d) = Vec (a + c) (b + d)
```

```elm
-- Main.beni
double : a → a
    where a.add : a, a → a
double x = x.add x
```

### List patterns

Lists are written and matched with brackets. `…rest` takes the remaining
elements.

```elm
total : List Int → Int
total xs =
    case xs of
        [] →
            0

        [ x, …rest ] →
            x + total rest
```

### Colorless functions

There is no `async` and no `await`. A function that waits on the network is
called like any other function, and so are the functions that call it.

```elm
fetchName : Int → Result Http.Error String
fetchName id = Http.get { url = "/users/${String.fromInt id}", expect = Http.expectString }


greet : Int → String
greet id =
    case fetchName id of
        Ok name →
            "Hello, ${name}"

        Err _ →
            "Hello, stranger"
```

### A fiber runtime

Every program runs on a fiber runtime inspired by Effect. Cancellation,
timeouts, retries with backoff, races and bounded concurrency are part of the
standard library, and a cancelled fiber always runs its cleanup. Here up to
four pages load at a time, each retried with exponential backoff, and the whole
batch gives up after ten seconds.

```elm
backoff : Schedule.Schedule Http.Error
backoff = Schedule.exponential (Duration.millis 100) 2.0 ▷ Schedule.upTo (Duration.seconds 5)


loadAll : List Int → Maybe (Result Http.Error (List String))
loadAll pages = Task.timeout (Duration.seconds 10) λ⊤ →
    Task.forEachOk pages 4 λn → Task.retry backoff λ⊤ → fetchPage n
```

### Schemas

Zod-like validation is built into the language. Schemas are compiled down into
highly optimized JavaScript.

```elm
schema Item =
    id : Int
    title : String
    done : Bool


firstTitle : String → String
firstTitle json =
    case Item.parse json of
        Ok item →
            item.title

        Err _ →
            "invalid"
```

## Platforms

The language knows nothing about the browser or Node. A platform package
supplies what a program can do on a host: its `main`, its effects and its
bindings to JavaScript. Every line of JavaScript in a build lives in the
platform, written to report each documented failure as a typed value, so
libraries are pure Beni and cannot break the guarantees.

Beni ships with three platforms:

- **`node`**: command-line programs and server code.
- **`browser`**: web pages, with the DOM, HTTP, storage and routing.
- **`browser-tea`**: web pages written in The Elm Architecture.

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
