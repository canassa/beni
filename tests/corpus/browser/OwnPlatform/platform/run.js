// Writes the program's heading into the page.
export const run = (program) => {
  const document = globalThis.document;
  const heading = document.createElement("h1");
  heading.textContent = program.text;
  document.body.appendChild(heading);
};
