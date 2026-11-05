export const contains = (node, other) => { return node.contains(other); };
export const host_append = (parent, child) => { try { parent.appendChild(child); return null; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "HierarchyRequestError") throw error; return error; } };
export const host_textContent = (node) => { return node.textContent; };
export const setTextContent = (node, text) => { node.textContent = text; return null; };
