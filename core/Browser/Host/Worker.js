export const closeSelf = (ignored) => { globalThis.close(); return null; };
export const supported = (ignored) => { return typeof globalThis.Worker === "function"; };
export const tryCreate = (url, name, credentials) => { try { return { $: "Ok", a: new globalThis.Worker(url, { type: "module", name, credentials }) }; } catch (error) { if (error instanceof globalThis.DOMException && (error.name === "SyntaxError" || error.name === "SecurityError")) return { $: "Err", a: error.name }; if (error instanceof globalThis.TypeError) return { $: "Err", a: "TypeError" }; throw error; } };
export const endpoint = (worker) => { return worker; };
export const self = (ignored) => { return globalThis.self; };
export const post = (endpoint, payload) => { try { endpoint.postMessage(payload); return { $: "Ok", a: null }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "DataCloneError") throw error; return { $: "Err", a: "DataCloneError" }; } };
export const terminate = (worker) => { worker.terminate(); return null; };
export const toEventTarget = (endpoint) => { return endpoint; };
