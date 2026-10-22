// The sibling JavaScript of `Worker.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else. Each
// one catches the one failure the host documents for the call it makes, by
// its class, and throws anything else again (CLAUDE.md rule 9).

// `new URL(target, base)`: a `TypeError` when the target does not resolve
// (§9.12 (d), measured: "Unable to parse URL: /login" for a relative target
// given with no base). `Maybe`'s constructors are nullary `Nothing` and
// `Just a`, written as the platform's other siblings write them.
export const resolveUrl = (target, base) => {
  try {
    return { $: "Just", a: new URL(target, base).href };
  } catch (e) {
    if (!(e instanceof TypeError)) throw e;
    return "Nothing";
  }
};

// `idFromString`: a `TypeError` "Invalid Durable Object ID" for text that is
// not an id (§9.12 (d)).
export const idFromString = (namespace, text) => {
  try {
    return { $: "Just", a: namespace.idFromString(text) };
  } catch (e) {
    if (!(e instanceof TypeError)) throw e;
    return "Nothing";
  }
};
