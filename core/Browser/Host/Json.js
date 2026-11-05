export const host_parse = (text) => { try { return globalThis.JSON.parse(text); } catch (error) { if (!(error instanceof globalThis.SyntaxError)) throw error; return error; } };
export const stringify = (value) => { return globalThis.JSON.stringify(value); };
