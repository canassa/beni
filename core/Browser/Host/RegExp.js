export const host_group = (pattern, text, index) => { const match = pattern.exec(text); const group = match === null ? undefined : match[index]; return group; };
export const host_create = (pattern, flags) => { try { return new globalThis.RegExp(pattern, flags); } catch (error) { if (!(error instanceof globalThis.SyntaxError)) throw error; return error; } };
export const test = (pattern, text) => { return pattern.test(text); };
export const replace = (pattern, text, replacement) => { return text.replace(pattern, replacement); };
