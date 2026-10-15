// The bootstrap of the playground's output frame (docs/design/playground.md
// §5). The page inlines this file, and the emitted files as JSON, into the
// `srcdoc` of an `<iframe sandbox="allow-scripts">`; the frame has an opaque
// origin of its own, so a blob URL the page made would not load here.
//
// It makes a blob URL in the frame's own origin for each module,
// dependencies first, with each relative import specifier replaced by the
// blob URL of the file it names and `node:process` and `node:fs/promises`
// by small modules that report to the page; then it imports `_main.mjs`.
// What the program prints, logs or throws goes to the page by
// `postMessage`, from listeners: nothing here catches.
"use strict";
(() => {
  const post = (kind, text) => parent.postMessage({ beni: kind, text }, "*");
  // A value as text, for any value: `String` throws on an object with no
  // prototype.
  const show = (value) => (typeof value === "object" && value !== null && typeof value.toString !== "function" ? Object.prototype.toString.call(value) : String(value));
  const describe = (value) => (value instanceof Error ? (value.stack ?? show(value)) : show(value));
  addEventListener("error", (event) => post("error", event.error === undefined ? event.message : describe(event.error)));
  addEventListener("unhandledrejection", (event) => post("error", describe(event.reason)));
  for (const level of ["log", "info", "warn", "error"]) {
    const original = console[level].bind(console);
    console[level] = (...values) => {
      post("console", values.map(show).join(" "));
      original(...values);
    };
  }

  const files = JSON.parse(document.getElementById("beni-files").textContent);

  // The two modules of Node a program on the `node` platform imports
  // (`platforms/node/runtime.js` and `Io.js`): its output goes to the page,
  // and the page has no files to read.
  const shims = {
    "node:process": [
      'const write = (text) => parent.postMessage({ beni: "stdout", text: String(text) }, "*");',
      "export const stdout = { write };",
      "export default {",
      "  stdout,",
      '  set exitCode(code) { parent.postMessage({ beni: "exit", text: String(code) }, "*"); },',
      "};",
    ].join("\n"),
    "node:fs/promises": [
      "export const readFile = (path) =>",
      '  Promise.reject(Object.assign(new Error(`ENOENT: the playground has no file ${path}`), { code: "ENOENT" }));',
    ].join("\n"),
  };

  const blob = (text) => URL.createObjectURL(new Blob([text], { type: "text/javascript" }));
  const urls = new Map();
  const visiting = new Set();

  // `spec`, relative to the file at `from`, as a path of `files`.
  const join = (from, spec) => {
    const parts = from.split("/").slice(0, -1);
    for (const segment of spec.split("/")) {
      if (segment === "..") parts.pop();
      else if (segment !== ".") parts.push(segment);
    }
    return parts.join("/");
  };

  // Where an import of `spec` from `from` goes.
  const target = (from, spec) => {
    if (Object.hasOwn(shims, spec)) {
      if (!urls.has(spec)) urls.set(spec, blob(shims[spec]));
      return urls.get(spec);
    }
    if (spec.startsWith("./") || spec.startsWith("../")) return url(join(from, spec));
    return spec;
  };

  // The import forms the compiler writes, one per line: `import … from
  // "…"`, `export … from "…"` and `import "…"` (playground.md §5). A
  // dynamic `import("./…")` of a module the build wrote cannot be rewritten
  // here, so a file with one is refused by name, not loaded wrongly.
  const fromClause = /^((?:import|export)\b[^\n]*?\bfrom\s*)(["'])([^"'\n]+)\2/gm;
  const bareImport = /^(import\s*)(["'])([^"'\n]+)\2/gm;
  const dynamicImport = /\bimport\s*\(\s*["']\.\.?\//;

  // The blob URL of the file at `path`, made after those of its imports.
  function url(path) {
    if (urls.has(path)) return urls.get(path);
    if (!Object.hasOwn(files, path)) throw new Error(`the build wrote no ${path}`);
    if (visiting.has(path)) throw new Error(`an import cycle through ${path}`);
    if (dynamicImport.test(files[path])) throw new Error(`${path} imports a module dynamically, which the playground does not load (playground.md §5)`);
    visiting.add(path);
    const text = files[path]
      .replace(fromClause, (_, head, quote, spec) => `${head}${quote}${target(path, spec)}${quote}`)
      .replace(bareImport, (_, head, quote, spec) => `${head}${quote}${target(path, spec)}${quote}`);
    visiting.delete(path);
    urls.set(path, blob(text));
    return urls.get(path);
  }

  import(url("_main.mjs")).then(() => post("loaded", ""));
})();
