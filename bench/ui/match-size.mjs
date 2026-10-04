// Research 56: what each prototype costs in bytes. A prototype is a hand edit
// of a development build, so neither it nor its base is release output;
// both are minified the same way (terser, compress and mangle, module) and
// compressed (brotli 11), and the difference is the estimate.
//
//   node match-size.mjs [--cases=holes-10,rows-30000,...]   (after match.mjs)

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";
import { root } from "./lib/serve.mjs";

const require = createRequire(join(root, "apps/solid1/package.json"));
const { minify } = require("terser");
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const br = (s) => brotliCompressSync(Buffer.from(s), { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const files = ["Main.mjs", "_platform/_browser/Rt.mjs", "_core/List.mjs"];

const size = async (dir) => {
  let raw = 0;
  let compressed = 0;
  for (const f of files) {
    const p = join(dir, f);
    if (!existsSync(p)) continue;
    const m = await minify(readFileSync(p, "utf8"), { module: true, compress: { passes: 2 }, mangle: true });
    raw += m.code.length;
    compressed += br(m.code);
  }
  return { raw, compressed };
};

const base = (c) => {
  if (c.startsWith("static")) return join(root, "out/micro-inline-dev");
  const [sweep, p] = c.split("-");
  return join(root, `out/scaling/${sweep === "burst" ? "holes" : sweep}/${sweep === "burst" ? 1000 : p}/beni-dev`);
};

const cases = arg("cases", null)?.split(",") ?? readdirSync(join(root, "out/match")).filter((d) => /-\d+$/.test(d));
for (const c of cases) {
  const b = await size(base(c));
  console.log(`${c}: base ${b.raw} raw, ${b.compressed} brotli (Main, Rt, List, minified)`);
  for (const v of readdirSync(join(root, "out/match", c)).sort()) {
    const s = await size(join(root, "out/match", c, v));
    console.log(`  ${v.padEnd(22)} ${String(s.raw - b.raw).padStart(6)} raw  ${String(s.compressed - b.compressed).padStart(5)} brotli`);
  }
}
