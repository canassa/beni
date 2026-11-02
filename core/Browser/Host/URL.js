export const protocol = (url) => { return url.protocol; };
export const setProtocol = (url, protocol) => { url.protocol = protocol; return null; };
export const tryCreate = (text, base) => { let value; if (globalThis.URL.parse === undefined) { try { value = new globalThis.URL(text, base); } catch (error) { if (!(error instanceof globalThis.TypeError)) throw error; return { $: "Nothing", a: null }; } } else { value = globalThis.URL.parse(text, base); } return value === null ? { $: "Nothing", a: null } : { $: "Just", a: value }; };
export const href = (url) => { return url.href; };
export const username = (url) => { return url.username; };
export const password = (url) => { return url.password; };
