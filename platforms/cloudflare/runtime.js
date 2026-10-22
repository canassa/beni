// The cloudflare platform's output shape (docs/design/boundary.md §5.2,
// §9.12 (b) and (c)): what the entry file hands `main` to.
//
// `run(program)` answers what the entry file exports: `default`, the
// Worker's handler table, whose `fetch` the host calls once per request,
// and `exports(name)`, called once at load for each name the app's
// `beni.json` lists. A Durable Object class is found by its export name,
// so a name the program defines nothing for fails the load here, with a
// message in beni's words rather than in Wrangler's; this slice defines no
// object (`Worker.Object.define` comes with the next), so every listed
// name fails. Everything else of the platform is beni over `Js`
// (`Worker.beni`) and its sibling.

export const run = (program) => ({
  default: { fetch: program.fetch },
  exports: (name) => {
    throw new Error(`the app's beni.json lists the export "${name}", and the program defines no Durable Object of that name (boundary.md §9.12 (c))`);
  },
});
