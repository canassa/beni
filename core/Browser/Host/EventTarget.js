export const current = (ignored) => { return globalThis; };
export const asAnchor = (target) => { return target instanceof globalThis.HTMLAnchorElement ? { $: "Just", a: target } : { $: "Nothing", a: null }; };
