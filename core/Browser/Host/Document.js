export const byId = (documentId) => { const element = globalThis.document.getElementById(documentId); return element === null ? { $: "Nothing", a: null } : { $: "Just", a: element }; };
export const fullscreenEnabled = (_) => { return globalThis.document.fullscreenEnabled === true; };
export const fullscreenElementId = (_) => { const element = globalThis.document.fullscreenElement; return element == null ? { $: "Nothing", a: null } : { $: "Just", a: element.id }; };
export const exitFullscreen = (_) => { return globalThis.document.exitFullscreen(); };
export const baseURI = (_) => { return globalThis.document.baseURI; };
export const title = (_) => { return globalThis.document.title; };
export const visibilityState = (_) => { return globalThis.document.visibilityState; };
export const setTitle = (title) => { globalThis.document.title = title; return null; };
export const listen = (name, handler) => { const target = globalThis.document; target.addEventListener(name, handler); return (_) => { target.removeEventListener(name, handler); return null; }; };
export const querySelector = (node, selector) => {
  try {
    const element = node.querySelector(selector);
    return { $: "Ok", a: element === null ? { $: "Nothing", a: null } : { $: "Just", a: element } };
  } catch (error) {
    if (!(error instanceof globalThis.DOMException) || error.name !== "SyntaxError") throw error;
    return { $: "Err", a: { $: "SyntaxError", a: null } };
  }
};
