export const append = (parent, child) => { try { parent.appendChild(child); return { $: "Ok", a: null }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "HierarchyRequestError") throw error; return { $: "Err", a: { $: "HierarchyRequestError", a: null } }; } };
export const textContent = (node) => { const text = node.textContent; return text === null ? { $: "Nothing", a: null } : { $: "Just", a: text }; };
export const setTextContent = (node, text) => { node.textContent = text; return null; };
