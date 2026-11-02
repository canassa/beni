export const isArray = (value) => { return globalThis.Array.isArray(value); };
export const isFinite = (value) => { return globalThis.Number.isFinite(value); };
export const isInteger = (value) => { return globalThis.Number.isInteger(value); };
export const isSafeInteger = (value) => { return globalThis.Number.isSafeInteger(value); };
export const keys = (value) => { return globalThis.Object.keys(value); };
export const emptyObject = (_) => { return globalThis.Object.create(null); };
export const hasOwn = (value, key) => { return globalThis.Object.hasOwn(value, key); };
