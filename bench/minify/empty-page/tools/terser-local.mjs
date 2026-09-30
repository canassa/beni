// terser's `compress` restricted to local, syntactic rewrites (no inlining,
// no cross-function facts, no renaming), over a step file: what a parser-level
// "compress" pass buys without whole-program knowledge. The output is printed
// so each rewrite it made can be read and priced alone.
//   TERSER=…/terser/main.js node tools/terser-local.mjs FILE
import fs from "node:fs";
import { pathToFileURL } from "node:url";
import { sizes } from "../measure.mjs";

const { minify } = await import(pathToFileURL(process.env.TERSER ?? new URL("../../../arrays/node_modules/terser/main.js", import.meta.url).pathname).href);
const src = fs.readFileSync(process.argv[2], "utf8");
const r = await minify(src, {
  module: true,
  compress: {
    inline: false, reduce_funcs: false, reduce_vars: false, toplevel: false, unused: false, collapse_vars: false,
    hoist_props: false, passes: 2, booleans: false, join_vars: false, sequences: false,
  },
  mangle: false,
});
console.log(r.code);
console.log("before", sizes(Buffer.from(src)), "after", sizes(Buffer.from(r.code)));
