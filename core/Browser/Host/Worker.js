export const closeSelf = (ignored) => { globalThis.close(); return null; };
export const supported = (ignored) => { return typeof globalThis.Worker === "function"; };
export const host_tryCreate = (url, name, credentials) => { try { return new globalThis.Worker(url, { type: "module", name, credentials }); } catch (error) { if (error instanceof globalThis.DOMException && (error.name === "SyntaxError" || error.name === "SecurityError")) return error; if (error instanceof globalThis.TypeError) return error; throw error; } };
export const endpoint = (worker) => { return worker; };
export const self = (ignored) => { return globalThis.self; };
export const host_post = (endpoint, payload) => { try { endpoint.postMessage(payload); return null; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "DataCloneError") throw error; return error; } };
export const terminate = (worker) => { worker.terminate(); return null; };
export const toEventTarget = (endpoint) => { return endpoint; };
