export const create = (_) => { return new globalThis.Headers(); };
export const append = (headers, name, value) => { headers.append(name, value); return null; };
export const has = (headers, name) => { return headers.has(name); };
export const set = (headers, name, value) => { headers.set(name, value); return null; };
export const host_get = (headers, name) => { return headers.get(name); };
export const entries = (headers) => { return Array.from(headers, entry => ({ a: entry[0], b: entry[1] })); };
