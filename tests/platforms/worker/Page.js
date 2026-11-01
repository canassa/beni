export const text = (value) => {
  let output = globalThis.document.querySelector("output");
  if (output === null) {
    output = globalThis.document.createElement("output");
    globalThis.document.body.appendChild(output);
  }
  output.textContent = value;
};
export const initializer = (value) => { globalThis.document.body.dataset.page = value; return value; };
export const button = (callback) => {
  const button = globalThis.document.createElement("button");
  button.textContent = "launch";
  button.addEventListener("click", () => callback(null));
  globalThis.document.body.appendChild(button);
};
