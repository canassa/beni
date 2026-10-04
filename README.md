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

The power of type classes without the complexity. A type's methods are the
functions its module exports, so `price.add tax` calls `Money.add`. Generic
code asks for a method with `where`, and the compiler finds it in the module
that declares the type. There are no instance declarations, no orphan rules
and no global coherence checks, because there is only ever one place to look.
Every call is resolved at compile time and costs the same as a direct function
call.

```elm
-- Money.beni
pub type Money
    = Cents Int


pub add : Money, Money → Money
add (Cents a) (Cents b) = Cents (a + b)
```

```elm
-- Main.beni
import Money exposing (Money)


clamp : a, a, a → a
    where a.compare : a, a → Order
clamp low high x =
    if x < low then
        low
    else if x > high then
        high
    else
        x


withFee : Money, Money → Money
withFee amount fee = clamp (Money.Cents 0) (Money.Cents 10000) (amount.add fee)
```

`==` and `<` are methods too. They call the type's `eq` and `compare`, and the
compiler derives both when a type does not write its own. That is why `clamp`
works on `Money` here without any extra code.

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

There is no `async` and no `await`. The compiler infers which functions may
wait, and the runtime suspends and resumes them. A newer search below cancels
the one still sleeping.

```elm
update msg model =
    case msg of
        Typed q →
            ( { model | query = q }, Cmd.keyed Search Cmd.Restart (search q _) )

        Found hits →
            ( { model | results = hits }, Cmd.none )


search : String, Cmd.Send Msg → ⊤
search q send =
    Time.sleep (Time.millis 250)
    send (Found (lookup q))
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

A `schema` describes data from outside the program, such as JSON. It compiles to
a parser and a printer, and a parse failure is a typed value, not an exception.

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
