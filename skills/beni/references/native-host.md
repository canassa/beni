# Native host operations

The `Browser.Host` modules expose opaque native types and typed operations.
A native object has its host representation. `Element.toNode` is an explicit
identity upcast. There is no implicit native subtyping.

`Document.querySelector` returns `Result QueryError (Maybe Element)`. An invalid
selector returns `SyntaxError`. Other unexpected host failures stop the program.
`Node.textContent` returns `Maybe String`. `Node.setTextContent` writes a String.
`Window.document` supplies the page document.

`TextEncoder.create` and `TextEncoder.encode` run in a page, a browser worker or Node.
`Uint8Array.byteLength` reads the size of the encoded data. `Timers.setTimeout`
takes a synchronous callback and a delay. `WorkerGlobalScope.self` runs only in
browser workers.

The compiler infers realm availability through calls and callbacks. A worker
that reaches a page operation reports `worker_realm_violation`. The diagnostic
names the operation, entry realm, allowed realms and call chain. An unreachable
declaration does not restrict an entry. An evaluated initializer does.

Stored callbacks restrict the writer's realm. This includes Ref, Js.Ref, Deferred
and Queue writes. A foreign function that returns a callback receiver keeps
the callback dependency on that returned function.

A generic storage or erasure helper keeps realm obligations on its type
variables. The compiler checks them when each caller supplies a type.
This also applies to dot calls, function aliases and imported helpers.
A page can use a helper with a DOM callback while a worker uses the same
helper with a portable callback.

A platform declares the top entry realm with `entryHost`. Each `entryKinds`
row declares its own realm. Without `entryHost`, an entry has an unknown realm
and accepts only operations available in all known realms. The old `host: page` key reports
`obsolete_host_promise`. Worker launch support remains gated while the other
worker checks are under construction.

Design: `workers.md` §4; `workers-native-bindings.md`.

A worker build checks its retained code after dead-code removal. A kept
`Js.global` name, a `globalThis` or `self` member and a free name in a kept
sibling `.js` file must be on the global object of that worker realm. The
list comes from the WebIDL of the web platform and the ECMAScript globals.
`worker_realm_violation` names the offending kept declaration or file and
access. Computed names and passing `Js.global` as a value are unproved.
`Function` and `eval` are refused in a worker, because the check cannot see
the code that they run. In a kept sibling, a name is free when no scope
around the read binds it. A kept sibling can call `setTimeout` or
`setInterval` only with a function as the first argument: a function
expression, an arrow, or a name bound to a function. `importScripts` reports
`module_worker_import_scripts`: a module worker does not have it. Use a
static import.

`Js.isUndefined (Js.global "name")` is a runtime probe. A local set to
`Js.global "name"` is a probe too when each read of it is the subject of
`Js.isUndefined` or `Js.typeIs`, or is in the branch where the probe proves
the name exists. A release worker writes `globalThis.name` for a name that
the realm does not have, so the probe gives the same result as in
development. A worker
has its own `location` and `navigator`: `location.href` and navigator language
reads work, but Location navigation methods do not. Unused page declarations
are allowed. This adds no runtime guard.

`Http` and `WebSocket` resolve relative URLs against the worker entry's URL.
Pages keep document-base semantics, including a `<base>` element. Entry-specific compilation removes the unused URL-base branch before emission.

Kept `globalThis`, `self`, `location` and `navigator` handles must be direct
receivers of literal members available in that worker realm. Aliasing,
storing/passing the handle, computed members and receiver writes are refused.
Literal root/member chains obey the same rule. WorkerLocation is read-only;
WorkerNavigator uses its worker-exposed IDL members. Animation frame APIs are
available in dedicated workers, not shared/service workers. The diagnostic
names the JavaScript access that is not proved available in the entry realm.
