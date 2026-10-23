## 2026-10-22 23:42 UTC — post and ask travel over RPC

**What I did**

- Cesar answered `cf-workers-q13` with A: RPC is the transport of `post` and `ask`, the
  protocol stays the one surface. The spec is §9.12 (e.11), from the local draft, with (e.10)'s
  as-built note and (j) amended.
- The object's class has one RPC method, `$beni(chain, kind, id, text)`, on a prototype chain
  over `DurableObject` made with `Reflect.construct`, so `runtime.js` keeps its function form
  and the release compactor sees no `class`. The asker reads a tagged result (`cycle`,
  `unparsed`, `none`, `reply`) instead of HTTP statuses and headers; the `/__beni/post` and
  `/__beni/ask` paths and the origin mark are gone from the object.
- `workers/ObjectRpc`: two objects over RPC — a relay of asks, the refused cycle, and a Pong
  that throws while it holds the Ping's ask, which the Ping sees as `Err Reset` before the Pong's
  next event starts a new instance.

**What I learned**

- An RPC call carries no headers, so the chain id travels as an argument; the cycle refusal then
  needs no transport knowledge at all, only the parked chain.
- The draft said no compiler change was needed; the probe had measured the host, not the
  compactor. The release compactor hoists imports of `node:` built-ins only, so `cloudflare:`
  joins the rule, with the same reason. Without the base the host refuses RPC with a `TypeError`.
- A receiver's defect reaches an asker as the host's reset, the same way under RPC as under
  `stub.fetch`: the abort rejects every pending call to the object.
