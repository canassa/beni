export const create = (_) => { return new globalThis.AbortController(); };
export const signal = (controller) => { return controller.signal; };
export const abort = (controller) => { controller.abort(); return null; };
