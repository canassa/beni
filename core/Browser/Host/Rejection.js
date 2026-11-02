export const isError = (reason) => { return reason instanceof globalThis.Error; };
export const name = (reason) => { return reason instanceof globalThis.Error ? reason.name : ""; };
export const code = (reason) => { return reason instanceof globalThis.Error && typeof reason.code === "string" ? { $: "Just", a: reason.code } : { $: "Nothing", a: null }; };
export const raise = (reason) => { throw reason; };
