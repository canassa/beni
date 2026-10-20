## 2026-10-20 21:51 CEST — specify the Cloudflare platform

**What I did**

- Read the platform contract (`boundary.md` §4, §5, §9.1, §9.8.14, §9.8.15, §9.10), the `node` platform, `core/Task.beni`, the entry-file emitter and the corpus kinds.
- Read Cloudflare's documentation for Workers, Durable Objects, the WebSocket Hibernation API, alarms, storage, the lifecycle and the Wrangler configuration.
- Wrote `boundary.md` §9.12: the `cloudflare` platform package, its manifest, the generated entry file, the `Worker`, `Worker.Object`, `WebSocket` and `Worker.Storage` APIs, the failures as typed errors, the Wrangler configuration and the tests.
- Added the `"exports"` output key to §5.2 and the app's `"exports"` list to `frontend.md` §10.1.
- Pointed the server WebSocket at §9.11 (PR #531, the `ws` worker's spec): the common surface and the upgrade keep its shape, and hibernation removes `read` and the session fiber.
- Asked Cesar three decisions on the dashboard: the platform's name, the shape of a Durable Object, and how the class names reach the entry file.

**What I learned**

- ES module exports are static, and Wrangler finds a Durable Object class by its export name. The entry file must know the class names when it is written, so the app's manifest lists them.
- A `sync` handler keeps the host's one-event-at-a-time delivery visible in beni. A handler that suspends would interleave with other events and break the state threading.
- A set timer stops hibernation. A declared `tick : state → Maybe Duration` turns "stop the tick when idle" into `Nothing`.
- A SQLite-backed object has a synchronous key-value store, so storage needs no suspension. Values cross as JSON text through a schema, because a release build renames record fields.
- nixpkgs `wrangler` 4.93.0 bundles Miniflare and `workerd`; it is 2.2 GB in the store. `nix search` of all of nixpkgs took the machine down; one attribute under `nix eval` is cheap.
