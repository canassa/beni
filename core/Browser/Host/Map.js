export const make = (ignored) => { return new globalThis.Map(); };
export const host_get = (map, key) => map.get(key);
export const has = (map, key) => map.has(key);
export const set = (map, key, value) => { map.set(key, value); return null; };
export const remove = (map, key) => { map.delete(key); return null; };
export const entries = (map) => { return Array.from(map, pair => ({ a: pair[0], b: pair[1] })); };
