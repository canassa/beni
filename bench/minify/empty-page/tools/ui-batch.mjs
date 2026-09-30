// Prepares one bench/ui batch: the table app built `--release` against the
// current runtime (`beni-release`, bench/ui's own subject) and against
// src/runtime.final.js (`beni-min`, an extra subject), beside Solid 1.
//   node tools/ui-batch.mjs [--from=<a checkout whose bench/ui/out has css/, jfb/, solid1/>]
// then, in `nix develop .#browser`:
//   node bench/ui/bench.mjs --subjects=beni-release,beni-min,solid1 --n=5 --out=out/minify-empty-page.json
//   node bench/ui/report.mjs out/minify-empty-page.json
// Only the runtime differs between the two beni subjects: both are built by
// the same beni from the same app.
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { patchedPlatforms } from "../measure.mjs";

const here = new URL("..", import.meta.url).pathname;
const repo = join(here, "../../..");
const ui = join(repo, "bench/ui");
const beni = process.env.BENI ?? join(repo, "zig-out/bin/beni");
const from = process.argv.find((a) => a.startsWith("--from="))?.slice(7);

mkdirSync(join(ui, "out"), { recursive: true });
if (from) for (const d of ["css", "jfb", "solid1"]) cpSync(join(from, "bench/ui/out", d), join(ui, "out", d), { recursive: true });
for (const d of ["css", "jfb", "solid1"]) if (!existsSync(join(ui, "out", d))) throw new Error(`bench/ui/out/${d} is missing: run bench/ui/build.mjs, or pass --from=`);

const sources = readdirSync(join(ui, "apps/beni")).filter((f) => f.endsWith(".beni")).sort().map((f) => `apps/beni/${f}`);
const build = (platform, out) => {
  rmSync(join(ui, out), { recursive: true, force: true });
  const r = spawnSync(beni, ["build", `--platform=${platform}`, "--release", "--no-cache", `--out=${out}`, ...sources], { cwd: ui, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`${out}: ${r.stdout}${r.stderr}`);
};
build("browser-tea", "out/beni-rel");
const root = patchedPlatforms(join(here, "src/runtime.final.js"));
build(join(root, "browser-tea"), "out/beni-min");
rmSync(root, { recursive: true, force: true });
writeFileSync(join(ui, "out/extra-subjects.json"), JSON.stringify([{ name: "beni-min", kind: "beni", dir: "beni-min" }]));
console.log("built out/beni-rel and out/beni-min");
