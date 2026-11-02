export const createOutput = (document, value) => {
  const output = document.createElement("output");
  output.textContent = value;
  document.body.appendChild(output);
  return null;
};
export const setPage = (element, value) => { element.dataset.page = value; return value; };
export const addButton = (document, callback) => {
  const button = document.createElement("button");
  button.textContent = "launch";
  button.addEventListener("click", () => callback(null));
  document.body.appendChild(button);
  return null;
};
