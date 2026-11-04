export const make = (ignored) => new globalThis.Set();
export const add = (set, value) => { set.add(value); return null; };
export const has = (set, value) => set.has(value);
export const size = (set) => set.size;
export const clear = (set) => { set.clear(); return null; };
export const each = (set, callback) => { set.forEach(callback); return null; };
