---
name: beni
description: Write, read or review beni code. beni is an Elm-like language that compiles to JavaScript, and Elm code fails in it. There is no currying (every call is saturated, `f a _` is partial application), static dispatch (`x.m a`, `where` clauses), array-backed lists written `[ x, …rest ]` with no `::`, Unicode notation (`→ ← ≠ ≤ ≥ ▷ ◁ …`), `⊤` and `⊥` for `()` and `Never`, `λ` lambdas, blocks instead of `let … in`, and inferred effects with no `Task e a` type. Read this skill before you write or change a `.beni` file, a `beni.json` or a `beni` command line, also when you know Elm well.
---

# beni

beni keeps Elm's guarantees: no runtime exceptions, exhaustive matches, immutable values, managed
effects. It is not Elm. Code that is valid Elm is refused with a named diagnostic. Read the rules
below first. Then open the reference file that your task needs. Run `beni check <path>` on what
you wrote, and `beni fmt <path>` before you show it.

## The rules an Elm programmer breaks first

1. **Every call is saturated.** A function type is n-ary: `add : Int, Int → Int`, not
   `Int → Int → Int`. Supply every argument. For partial application write `add 1 _`.
2. **The library is subject first and function last.** `List.map xs f`, `String.split s ","`,
   `Dict.get d key`. A pipe inserts at the first argument: `xs ▷ List.map f`.
3. **Unicode notation.** Write `→` for `->`, `←` for `<-`, `≠` `≤` `≥`, `▷` for `|>`, `◁` for `<|`,
   `…` for a spread, `×` in a tuple type. The ASCII spelling is an error. `&&`, `||`, `==` and `++`
   stay ASCII.
4. **`⊤` is the unit type and value; `⊥` is the empty type.** `()` and `Never` are errors.
   `init : ⊤ → Model`, `λ⊤ → e`, `main = Io.run λ⊤ → …`.
5. **No `::`.** A list is written, built and matched with brackets and a spread:
   `[ x, …rest ]`, `[ …xs, x ]`, `[ …a, …b ]`. A list grows at its end: `List.push xs x`.
6. **`λx → e` is the only lambda.** `\x -> e` is an error. The last argument of a call can be a
   lambda without parentheses: `List.map xs λx → x * 2`.
7. **No `let … in`.** A body written as lines is a block: bindings, statements and a last line
   that is the value. `x ← f a` binds the rest of the block as `f`'s callback.
8. **No module header.** The module name comes from the file path. Mark exports with `pub` on each
   declaration. `import M exposing (T, Ctor1, Ctor2)` lists constructors by name; `T(..)` is an error.
9. **`x.m a` is a method call** when `x` has a nominal type: it calls `m` from the module that
   declares the type. `==` and `<` call the type's `eq` and `compare`, derived when none is declared.
   A type variable gets methods through a `where` clause on the annotation.
10. **Effects have no syntax.** A function that waits is written like any other; the compiler infers
    it. There is no `Task e a` type: `user = getUser id` performs the request. On `browser-tea`,
    `update` returns a `Cmd` that names the work, and the work's body calls such functions.
    Failures are `Result` values. A defect stops the program.
11. **`Int.mod n 2`, `Int.rem n 3`, `Float.log x 10`.** `modBy`, `remainderBy` and `logBase` are
    gone. `Debug.log "label" value` keeps Elm's order, and a `--release` build refuses `Debug`.
12. **A write edits a list in place where the compiler can prove it safe.** On the `browser-inline`
    platform a write to a list that is read again later is the error `list_still_used`, and
    `List.copy` is the fix. On the other platforms such a write copies. A record update
    `{ r | a = 1 }` follows the same rule: a later use of the old `r` whole there is the error
    `record_still_used`, and `{ Record.copy r | a = 1 }` is the fix. An untouched record field
    keeps its identity across the update.

## The smallest programs

A `node` program prints and exits:

```beni platform=node
import Node exposing (Program)


main : Program
main = Node.print "hello"
```

A page with a model, on `browser-tea`:

```beni platform=browser-tea
import Html exposing (Html)
import Tea


type Msg
    = Increment


update : Msg, Int → Int
update msg n =
    case msg of
        Increment →
            n + 1


view : Int → Html Msg
view n = <button onClick={Increment}>{n}</button>


main : Tea.Program
main = Tea.sandbox { init = λ⊤ → 0, update = update, view = view }
```

Build and run: `beni new <dir>` writes a project; `beni build` compiles it to `out/`; `node out/_main.mjs`
runs a `node` program; `beni serve` serves a page with live reload.

## References

Open the file that your task needs. Each is short.

- `references/syntax.md` — files and modules, `pub`, imports, comments, strings, layout, blocks, `λ`,
  `⊤` and `⊥`, `if` without `else`, the Unicode notation, records, tuples, `?`.
- `references/calls.md` — saturated calls, `_`, `▷` and `◁`, `←`, subject first, the renamed Elm functions.
- `references/lists.md` — brackets and `…`, patterns, costs, `prepend_in_loop`, ownership: `list_still_used`
  and `List.copy`.
- `references/types-and-dispatch.md` — custom types, `pub opaque`, record aliases, methods and `x.m a`,
  `where`, `eq` and `compare`, return-type dispatch, `Dict` and `Set` keys.
- `references/effects.md` — the two inferred bits, `Result` and no exceptions, `Task`, `Ref`, `Deferred`,
  `Debug` in a release build, `Log`.
- `references/schemas.md` — the `schema` declaration, `Type` and `Encoded`, `parse` and `print`, the modifiers,
  `tagged`, `Json` with a derived `codec`.
- `references/markup.md` — elements, attributes, holes, events, components, `For`, `Show`, `class` and `style`
  lists, `Html.map`, what is refused.
- `references/platforms.md` — `node`, `browser`, `browser-tea`, `browser-inline`, `html` and `cloudflare`: what `main` is on
  each, commands, subscriptions and the modules each adds.
- `references/websocket.md` — the `WebSocket` module: the shared operations, a server on `node` with
  `listenWith`, `accept` and `refuse`, and a page on `browser-tea` with `listen` and `send`.
- `references/project.md` — `beni.json`, `beni new`, the output tree, `beni serve`.
- `references/cli.md` — every command and flag of `beni help`, the exit codes, `--diagnostics=json`.
- `references/api-core.md` — the public interface of every core module, generated by the compiler.
- `references/api-node.md`, `references/api-browser.md`, `references/api-browser-tea.md`,
  `references/api-browser-inline.md`, `references/api-html.md`, `references/api-cloudflare.md` — the public interface of each platform,
  generated by the compiler. `api-html.md` lists every element, attribute and event of the markup vocabulary.

A generated file writes each signature in beni's notation: `List a, (a → b) → List b`. Effects are
inferred and never written. A value whose result reaches the host ends in the comment `-- impure`; one
that can wait ends in `-- suspends`. Nothing else in a signature says anything about effects.
