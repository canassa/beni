// The cloudflare platform's output shape (docs/design/boundary.md §5.2,
// §9.12 (b) and (c)): what the entry file hands `main` to.
//
// `run(program)` answers what the entry file exports: `default`, the
// Worker's handler table, whose `fetch` the host calls once per request,
// and `exports(name)`, called once at load for each name the app's
// `beni.json` lists: the Durable Object of the definition of that name
// among the program's `objects` (`Worker.Object.define`). It is found by
// its export name, so a name the program defines nothing for fails the
// load here, with a message in beni's words rather than in Wrangler's.
// What is exported is a plain function the host calls with `new (ctx,
// env)`, built over `DurableObject` from `cloudflare:workers` through
// `Reflect.construct` so that the host offers RPC on its stub (§9.12
// (e.11)), with its methods on the prototype; the two keywords the release
// compactor cannot hoist past are kept out of this file. Each method hands
// its event to beni (`Worker/Object.beni`), and everything else of the
// platform is beni over `Js` and its siblings.

import { DurableObject } from "cloudflare:workers";

export const run = (program) => ({
  default: { fetch: program.fetch },
  exports: (name) => {
    const definition = program.objects.find((d) => d.name === name);
    if (definition === undefined) {
      throw new Error(`the app's beni.json lists the export "${name}", and the program defines no Durable Object of that name (boundary.md §9.12 (c))`);
    }
    function Instance(ctx, env) {
      const self = Reflect.construct(DurableObject, [ctx, env], new.target ?? Instance);
      self.$ = definition.start(ctx, env, definition.worker);
      return self;
    }
    Object.setPrototypeOf(Instance.prototype, DurableObject.prototype);
    Object.setPrototypeOf(Instance, DurableObject);
    Instance.prototype.fetch = function (request) {
      return this.$.fetch(request);
    };
    Instance.prototype.alarm = function () {
      return this.$.alarm(null);
    };
    // The one RPC method, the transport of `post` and `ask` (§9.12 (e.11)).
    Instance.prototype.$beni = function (chain, kind, id, text) {
      return this.$.rpc(chain, kind, id, text);
    };
    Instance.prototype.webSocketMessage = function (ws, message) {
      return this.$.webSocketMessage(ws, message);
    };
    Instance.prototype.webSocketClose = function (ws, code, reason, wasClean) {
      return this.$.webSocketClose(ws, code, reason, wasClean);
    };
    Instance.prototype.webSocketError = function (ws, error) {
      return this.$.webSocketError(ws, error);
    };
    return Instance;
  },
});
