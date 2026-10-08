// Width sweep: price the release build's short record field names against
// the source names (f0…fW−1) brotli can predict. The release init literal
// maps each short name to its field's index (field fK is initialised to K).
import { createRequire } from "node:module";
import { join } from "node:path";
import { root } from "./lib/serve.mjs";
import { readFileSync } from "node:fs";
import { brotliCompressSync, constants } from "node:zlib";
const require = createRequire(join(root, "apps/solid2/package.json"));
const { minify } = require("terser");
const br = (s) => brotliCompressSync(Buffer.from(s), { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: s.length } }).length;
for (const w of process.argv.slice(2)) {
  const src = readFileSync(`${root}out/scaling/width/${w}/beni-rel/_main.mjs`, "utf8");
  const init = /init:\{([^}]*)\}/.exec(src) ?? /=\{((?:[\w$]+:\d+,?){20,})\}/.exec(src);
  const map = new Map(init[1].split(",").map((kv) => kv.split(":")).map(([k, v]) => [k, `f${v}`]));
  // property reads `.k` and keys `k:` of the init literal only
  let renamed = src.replace(/\.([\w$]+)\b/g, (m, k) => (map.has(k) && !/^(data|firstChild|nextSibling)$/.test(k) ? `.${map.get(k)}` : m));
  renamed = renamed.replace(init[0], init[0].replace(/([\w$]+):/g, (m, k) => (map.has(k) ? `${map.get(k)}:` : m)));
  const a = (await minify(src, { compress: true, mangle: true, module: true })).code;
  const b = (await minify(renamed, { compress: true, mangle: true, module: true })).code;
  console.log(w, "short names", br(a), "source names", br(b));
}
