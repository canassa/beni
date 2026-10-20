## 2026-10-20 14:21 UTC — release keeps implicit object keys

**What I did**

`run/ReleaseImplicitKeys` builds a `Js.object` with `valueOf` and
`toString`, and a later `Js.set` of `valueOf`. An arrow is not
`Js.method`, so the object does not escape. Development printed `1`,
`x5y` and `1`. Release printed `0`, `x[object Object]y` and `0`.

Fact 3 treats a missing member read as unread. `dropKeys` and
`deadWrite` both drop an inert key on that fact. `&` and a template
call `ToPrimitive` with no member read, and fact 3 records a
primitive. `implicit_host_keys` is `toJSON`, `toString` and `valueOf`.
Both predicates refuse those ids. `pad` still drops. Both builds now
print the same three lines.

A well-known symbol is not a string name. `Js.object` accepts
identifier keys only, so `Symbol.toPrimitive` is not a `.property`.
`keyUnread` already keeps a key it cannot name. `then` stays off the
list. A call the pass cannot see escapes the object, and an unread
`then` inside the program is data.

**What I learned**

The two drop predicates share one definition of unread. Fixing the
literal and leaving the later write dropped `valueOf` on the
assignment path. `JSON.stringify` of `toJSON` did not go red, because
that call escapes the object and keeps every key. The name stays on
the list because the read is not a member expression.
