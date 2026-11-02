// Core's native boundary: no host object travels through Js.Value.
const parkedValue = {};
let macroPort;
const macroQueue = [];

export const parked = (unit) => parkedValue;
export const microtask = (work) => {
  globalThis.queueMicrotask(() => work(null));
  return null;
};
export const macrotask = (work) => {
  if (typeof globalThis.setImmediate === "function") {
    globalThis.setImmediate(() => work(null));
  } else {
    if (!macroPort) {
      const channel = new globalThis.MessageChannel();
      channel.port1.onmessage = () => {
        const next = macroQueue.shift();
        if (next) next(null);
      };
      macroPort = channel.port2;
    }
    macroQueue.push(work);
    macroPort.postMessage(null);
  }
  return null;
};
export const timer = (milliseconds, work) => {
  const handle = globalThis.setTimeout(() => work(null), milliseconds);
  return (unit) => {
    globalThis.clearTimeout(handle);
    return null;
  };
};
export const now = (unit) => globalThis.Date.now();
export const random = (unit) => globalThis.Math.random();
export const defect = (message) => { throw new Error(message); };
