export const localName = (element) => { return element.localName; };
export const styleText = (element, value) => { element.setAttribute("style", value); return null; };
export const focus = (element) => { element.focus(); return null; };
export const blur = (element) => { element.blur(); return null; };
export const box = (element) => { return element.getBoundingClientRect(); };
export const scrollTo = (element, x, y) => { element.scrollTo(x, y); return null; };
export const scrollIntoView = (element) => { element.scrollIntoView(); return null; };
export const fullscreenSupported = (element) => { return typeof element.requestFullscreen === "function"; };
export const requestFullscreen = (element) => { return element.requestFullscreen(); };
export const host_querySelector = (node, selector) => {
  try {
    const element = node.querySelector(selector);
    return element;
  } catch (error) {
    if (!(error instanceof globalThis.DOMException) || error.name !== "SyntaxError") throw error;
    return error;
  }
};
export const host_getAttribute = (element, name) => { return element.getAttribute(name); };
export const toNode = (element) => { return element; };
