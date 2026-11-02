export const trySchedule = (work) => { if (typeof globalThis.setImmediate !== "function") return false; globalThis.setImmediate(() => work(null)); return true; };
