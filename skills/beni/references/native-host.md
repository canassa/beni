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

Generic erasure through an unknown type variable has a known gap. Core and
platform code must keep concrete callback types until generic realm
obligations are implemented.

A platform declares the top entry realm with `entryHost`. Each `entryKinds`
row declares its own realm. Without `entryHost`, an entry has an unknown realm
and accepts only operations available in all known realms. The old `host: page` key reports
`obsolete_host_promise`. Worker launch support remains gated while the other
worker checks are under construction.

Design: `workers.md` §4; `workers-native-bindings.md`.
