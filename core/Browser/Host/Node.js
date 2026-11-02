export const textContent = (node) => { const text = node.textContent; return text === null ? { $: "Nothing", a: null } : { $: "Just", a: text }; };
export const setTextContent = (node, text) => { node.textContent = text; return null; };
