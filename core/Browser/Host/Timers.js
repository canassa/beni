export const queueMicrotask = (work) => { globalThis.queueMicrotask(() => work(null)); return null; };
export const start = (work, delay) => { return globalThis.setTimeout(() => work(null), delay); };
export const clear = (timer) => { globalThis.clearTimeout(timer); return null; };
export const setTimeout = (callback, delay) => { return globalThis.setTimeout(() => callback(null), delay); };
