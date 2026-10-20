## 2026-10-20 18:36 UTC — release keeps a proto set

**What I did**

`run/ReleaseProtoSet` sets `__proto__` and then coerces with `&`, calls a
setter, reads an inherited field, and does the same setter through
`Js.setAt` of the string literal at the write site. Development printed
`1`, `1`, `9` and `1`. Release printed `0`, `0`, `undefined` and `0`.

The write escapes the object. Release now prints the same four lines.
The run hash is Node v24.19.0. No other program's output moved.

Rebased onto `8ecb487`. No run hash moved. The two unfixed cases are #519 and #520.

`Js.object [ ( "__proto__", p ) ]` does not compile. Development and
release both report `invalid_js_object` and write no JavaScript. The
check fixture is `check/bad/core/JsObjectKey`.

**What I learned**

`neverRead` is the wrong test for a `__proto__` write. The assignment
sets `[[Prototype]]`, so a later read or write is not an own data
property. Escaping the object covers the assignment and what follows
it. The name does not belong on `implicit_host_keys`.

`Js.setAt` of a string literal at the write site is still an
`index_get`. The printer writes it as `a.__proto__=b`. A key that
comes from a `let` binding stays field-insensitive (#519). A setter
installed on `Object.prototype` is #520.

An assignment target is an `ident`, a `member` or an `index_get`. No
other form writes `__proto__`.
