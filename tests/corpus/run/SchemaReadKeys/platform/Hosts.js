// Default non-enumerable class-like getters, as in the original fixture.
export const defineGetter = (out, key, get) => { Object.defineProperty(out, key, { get }); return null; };
