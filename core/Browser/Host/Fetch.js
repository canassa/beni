export const textBody = (text) => { return text; };
export const formBody = (form) => { return form; };
export const init = (method, headers, body, signal, credentials) => { return { body: body.$ === "Just" ? body.a : undefined, credentials, headers, method, mode: "cors", redirect: "follow", signal }; };
export const fetch = (url, init) => { return globalThis.fetch(url, init); };
