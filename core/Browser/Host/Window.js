export const scrollX = (_) => { return globalThis.scrollX; };
export const scrollY = (_) => { return globalThis.scrollY; };
export const requestFrame = (work) => { return globalThis.requestAnimationFrame(() => work(null)); };
export const cancelFrame = (frame) => { globalThis.cancelAnimationFrame(frame); return null; };
export const innerWidth = (_) => { return globalThis.innerWidth; };
export const innerHeight = (_) => { return globalThis.innerHeight; };
export const listen = (name, handler) => { globalThis.addEventListener(name, handler); return (_) => { globalThis.removeEventListener(name, handler); return null; }; };
export const document = (_) => { return globalThis.document; };
