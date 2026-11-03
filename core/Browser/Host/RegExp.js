export const group = (pattern, text, index) => { const match = pattern.exec(text); const group = match === null ? undefined : match[index]; return group !== null && group !== undefined ? { $: "Just", a: group } : { $: "Nothing", a: null }; };
export const create = (pattern, flags) => { try { return { $: "Ok", a: new globalThis.RegExp(pattern, flags) }; } catch (error) { if (!(error instanceof globalThis.SyntaxError)) throw error; return { $: "Err", a: "SyntaxError" }; } };
export const test = (pattern, text) => { return pattern.test(text); };
export const replace = (pattern, text, replacement) => { return text.replace(pattern, replacement); };
