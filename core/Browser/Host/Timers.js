export const setTimeout = (callback, delay) => { return globalThis.setTimeout(() => callback(null), delay); };
