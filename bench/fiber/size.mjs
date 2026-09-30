// What the fiber runtime costs a program in bytes (docs/design/research/44-effects-runtime-spike.md §7):
// `node size.mjs <beni> <out dir>` builds apps/Plain.beni and
// apps/Fibers.beni as release applications — one scope-hoisted file each
// (backend.md §9) — and bundles apps/effect-fibers.mjs with esbuild, minified
// and tree-shaken, then prints raw, gzip and brotli sizes as JSON.

import { execFileSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, gzipSync, constants } from "node:zlib";
import { build } from "esbuild";

const here = fileURLToPath(new URL(".", import.meta.url));
const [beni, out] = process.argv.slice(2);

const sizes = (label, bytes) => ({
  label,
  raw: bytes.length,
  gzip: gzipSync(bytes, { level: 9 }).length,
  brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length,
});

const rows = [];
for (const app of ["Plain", "Fibers"]) {
  const dir = join(out, app);
  rmSync(dir, { recursive: true, force: true });
  execFileSync(beni, ["build", "--release", "--platform=node", `--out=${dir}`, join(here, "apps", `${app}.beni`)], { stdio: "inherit" });
  rows.push(sizes(`beni --release: apps/${app}.beni (_main.mjs, the whole program)`, readFileSync(join(dir, "_main.mjs"))));
}
const bundled = await build({
  entryPoints: [join(here, "apps/effect-fibers.mjs")],
  bundle: true,
  minify: true,
  format: "esm",
  platform: "browser",
  write: false,
  logLevel: "error",
});
rows.push(sizes("Effect v4 + esbuild --minify: apps/effect-fibers.mjs", Buffer.from(bundled.outputFiles[0].contents)));
console.log(JSON.stringify(rows, null, 1));
