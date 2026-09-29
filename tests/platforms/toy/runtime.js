// The toy platform's program runtime and markup runtime in one file
// (docs/design/boundary.md §9.2): `run` prints the view and the tags the
// program start data named, which the entry file hands `start` first.
import process from "node:process";

let tags = [];

export const start = (data) => {
  tags = data.tag;
};

export const run = (program) => {
  process.stdout.write(`${program.html.t}\ntags: ${tags.join(" ")}\n`);
};

export const quote = (value) => `"${value}"`;

export const text = (s) => ({ t: quote(s) });

export const map = (html, f) => html;
