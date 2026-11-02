export const parse = (text) => { try { return { $: "Ok", a: globalThis.JSON.parse(text) }; } catch (error) { if (!(error instanceof globalThis.SyntaxError)) throw error; return { $: "Err", a: "SyntaxError" }; } };
export const stringify = (value) => { return globalThis.JSON.stringify(value); };
