export const querySelector = (node, selector) => {
  try {
    const element = node.querySelector(selector);
    return { $: "Ok", a: element === null ? { $: "Nothing", a: null } : { $: "Just", a: element } };
  } catch (error) {
    if (!(error instanceof globalThis.DOMException) || error.name !== "SyntaxError") throw error;
    return { $: "Err", a: { $: "SyntaxError", a: null } };
  }
};
