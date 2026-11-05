export const run = (program) => {
  const root = document.body;
  const query = root.querySelector.bind(root);
  root.querySelector = (selector) => {
    if (selector === "[") throw new DOMException("invalid selector", "SyntaxError");
    return query(selector);
  };
  for (const [id, value] of [["present", "value"], ["empty", ""], ["absent", null]]) {
    const element = document.createElement("div");
    element.id = id;
    if (value !== null) element.setAttribute("data-value", value);
    root.appendChild(element);
  }
  const output = document.createElement("output");
  output.textContent = program.init(null);
  root.appendChild(output);
};
