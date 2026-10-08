// Solid 1.9.15's pieces for the table app's jobs, each minified and
// brotli 11 alone (the "alone" column of size-parts.mjs), from the
// package's own dist files.
import { createRequire } from "node:module";
import { join } from "node:path";
import { root } from "./lib/serve.mjs";
import { readFileSync } from "node:fs";
import { brotliCompressSync, constants } from "node:zlib";
const nm = join(root, "apps/solid1/node_modules") + "/";
const require = createRequire(join(root, "apps/solid2/package.json"));
const { minify } = require("terser");
const acorn = require(nm + "acorn");
const br = (s) => brotliCompressSync(Buffer.from(s), { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: s.length } }).length;
const files = { solid: readFileSync(nm + "solid-js/dist/solid.js", "utf8"), web: readFileSync(nm + "solid-js/web/dist/web.js", "utf8") };
const fns = {};
for (const [f, src] of Object.entries(files)) {
  for (const st of acorn.parse(src, { ecmaVersion: "latest", sourceType: "module" }).body) {
    if (st.type === "FunctionDeclaration") fns[st.id.name] = src.slice(st.start, st.end);
    if (st.type === "VariableDeclaration") for (const d of st.declarations) if (d.id.type === "Identifier") fns[d.id.name] = `${st.kind} ${src.slice(d.start, d.end)};`;
  }
}
const parts = [
  ["keyed list: mapArray + reconcileArrays", "mapArray reconcileArrays"],
  ["delegation: delegateEvents + eventHandler", "delegateEvents eventHandler $$EVENTS"],
  ["insert: insert, insertExpression, normalizeIncomingArray, cleanChildren", "insert insertExpression normalizeIncomingArray cleanChildren"],
  ["template", "template"],
  ["signals and scheduler: createRoot, createSignal, createRenderEffect, createMemo, readSignal, writeSignal, computations, runUpdates, queues, cleanNode, untrack, onCleanup, batch", "createRoot createSignal createRenderEffect createMemo readSignal writeSignal updateComputation runComputation createComputation runTop runUpdates completeUpdates runQueue runUserEffects lookUpstream markDownstream cleanNode untrack onCleanup batch handleError castError"],
];
for (const [label, names] of parts) {
  const text = names.split(" ").filter((n) => fns[n]).map((n) => fns[n]).join("\n");
  const missing = names.split(" ").filter((n) => !fns[n]);
  const code = (await minify(`${text}\nexport{${names.split(" ").filter((n) => fns[n]).join(",")}};`, { compress: true, mangle: true, module: true })).code;
  console.log(`| ${label} | ${code.length} | ${br(code)} |${missing.length ? ` missing: ${missing.join(" ")}` : ""}`);
}
