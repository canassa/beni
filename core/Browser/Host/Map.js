export const make = (ignored) => { return new globalThis.Map(); };
export const get = (map, key) => { return map.has(key) ? { $: "Just", a: map.get(key) } : { $: "Nothing", a: null }; };
export const set = (map, key, value) => { map.set(key, value); return null; };
export const remove = (map, key) => { map.delete(key); return null; };
export const entries = (map) => { return Array.from(map, pair => ({ a: pair[0], b: pair[1] })); };
