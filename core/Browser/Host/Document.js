export const getElementsByName = (name) => Array.from(globalThis.document.getElementsByName(name));
export const host_activeElement = (ignored) => { return globalThis.document.activeElement; };
export const controls = (ignored) => Array.from(globalThis.document.querySelectorAll("input,select,textarea,option"));
export const host_body = (unit) => { return globalThis.document.body; };
export const div = (unit) => { return globalThis.document.createElement("div"); };
export const host_byId = (documentId) => { return globalThis.document.getElementById(documentId); };
export const fullscreenEnabled = (_) => { return globalThis.document.fullscreenEnabled === true; };
export const host_fullscreenElementId = (_) => { const element = globalThis.document.fullscreenElement; return element == null ? undefined : element.id; };
export const exitFullscreen = (_) => { return globalThis.document.exitFullscreen(); };
export const baseURI = (_) => { return globalThis.document.baseURI; };
export const title = (_) => { return globalThis.document.title; };
export const visibilityState = (_) => { return globalThis.document.visibilityState; };
export const setTitle = (title) => { globalThis.document.title = title; return null; };
export const listen = (name, handler) => { const target = globalThis.document; target.addEventListener(name, handler); return (_) => { target.removeEventListener(name, handler); return null; }; };
export const host_querySelector = (node, selector) => {
  try {
    const element = node.querySelector(selector);
    return element;
  } catch (error) {
    if (!(error instanceof globalThis.DOMException) || error.name !== "SyntaxError") throw error;
    return error;
  }
};
