export const setAbandoned = (error, reports) => { error.abandonedWorkers = reports; return null; };
export const typeErrorMessage = (error) => { return error instanceof globalThis.TypeError ? { $: "Just", a: error.message } : { $: "Nothing", a: null }; };
export const isTypeError = (reason) => { return reason instanceof globalThis.TypeError; };
export const isError = (reason) => { return reason instanceof globalThis.Error; };
export const name = (reason) => { return reason instanceof globalThis.Error ? reason.name : ""; };
export const code = (reason) => { return reason instanceof globalThis.Error && typeof reason.code === "string" ? { $: "Just", a: reason.code } : { $: "Nothing", a: null }; };
export const raise = (reason) => { throw reason; };
