// Typed fixture boundary keeps interval handles and callbacks out of Js.Value.
export const interval = (send, ms) => globalThis.setInterval(send, ms);
export const clear = timer => { globalThis.clearInterval(timer); return null; };
