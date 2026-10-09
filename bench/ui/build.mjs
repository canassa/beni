// Builds every subject into bench/ui/out/ (git-ignored):
//
//   out/css/          js-framework-benchmark's stylesheet, fetched once
//   out/jfb/Main.js   its keyed vanillajs, fetched once (the calibration subject)
//   out/beni-dev/     apps/beni, `beni build --platform=browser-tea`
//   out/beni-rel/     the same with `--release`
//   out/beni-direct-*/ the same for `--platform=browser-direct`, or `.skipped`
//   out/micro-*/      the static-heavy pages, dev and release
//   out/solid2/       apps/solid2, Solid 2.0.0-rc.9 through Vite and terser
//   out/solid1/       apps/solid1, Solid 1.9.15 built as js-framework-benchmark's
//                     keyed solid entry is: Rollup, babel-preset-solid, terser
//
//   node build.mjs [--beni=<path to beni>] [--no-solid]
//
// The fetched files are pinned to one js-framework-benchmark commit and
// checked against the SHA-256 recorded here.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../..");
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const beni = arg("beni", join(repo, "zig-out/bin/beni"));

const JFB = "https://raw.githubusercontent.com/krausest/js-framework-benchmark/652198560d0ccdafb9be833dac53e154bd1a0d1d";
const fetched = [
  ["css/currentStyle.css", "out/css/currentStyle.css", "45f7d016571351942baf18489716fb342532a305feda38f2f98112109933e22c"],
  ["css/main.css", "out/css/main.css", "d8d5b527c71c8a71fd273310650180318f8e8361334d96c9a27bdc85fa1b75e3"],
  ["css/bootstrap/dist/css/bootstrap.min.css", "out/css/bootstrap/dist/css/bootstrap.min.css", "eece6e0c65b7007ab0eb1b4998d36dafe381449525824349128efc3f86f4c91c"],
  ["frameworks/keyed/vanillajs/src/Main.js", "out/jfb/Main.js", "08a5cb7d5cec199396561ed28b3c2db77577f066480f33c19f22ce6b0b0c980f"],
];

const run = (cmd, args, cwd = here) => {
  const r = spawnSync(cmd, args, { cwd, stdio: "inherit" });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")}: exit ${r.status}`);
};

for (const [from, to, sha] of fetched) {
  const dest = join(here, to);
  if (existsSync(dest)) continue;
  const res = await fetch(`${JFB}/${from}`);
  if (!res.ok) throw new Error(`fetch ${from}: ${res.status}`);
  const bytes = Buffer.from(await res.arrayBuffer());
  const got = createHash("sha256").update(bytes).digest("hex");
  if (got !== sha) throw new Error(`fetch ${from}: sha256 ${got}, expected ${sha}`);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, bytes);
  console.log(`fetched ${from}`);
}

// Every `.beni` file of the directory is one program.
const beniBuild = (dir, out, release) => {
  rmSync(join(here, out), { recursive: true, force: true });
  const sources = readdirSync(join(here, dir))
    .filter((f) => f.endsWith(".beni"))
    .sort()
    .map((f) => `${dir}/${f}`);
  run(beni, ["build", "--platform=browser-tea", ...(release ? ["--release"] : []), "--no-cache", `--out=${out}`, ...sources]);
};

beniBuild("apps/beni", "out/beni-dev", false);
beniBuild("apps/beni", "out/beni-rel", true);
// The same sources for `browser-direct` (docs/design/browser-direct.md
// §12.2). A program its slices cannot build yet is not built: `.skipped`
// holds the compiler's reason, and bench.mjs skips the subject with it.
for (const [out, release] of [["out/beni-direct-dev", false], ["out/beni-direct-rel", true]]) {
  rmSync(join(here, out), { recursive: true, force: true });
  const r = spawnSync(beni, ["build", "--platform=browser-direct", ...(release ? ["--release"] : []), "--no-cache", "--diagnostics=json", `--out=${out}`, "apps/beni/Main.beni"], { cwd: here, encoding: "utf8" });
  if (r.status !== 0) {
    const text = (r.stderr || r.stdout || "").trim();
    const first = text.startsWith("[") ? JSON.parse(text)[0] : null;
    mkdirSync(join(here, out), { recursive: true });
    writeFileSync(join(here, out, ".skipped"), first === null ? text : `${first.code}: ${first.message.replace(/\s+/g, " ")}`);
    console.log(`${out}: skipped (${first?.code ?? "build failed"})`);
  }
}
for (const v of ["Inline", "Helpers", "Components"]) {
  beniBuild(`apps/micro/beni/${v}`, `out/micro-${v.toLowerCase()}-dev`, false);
  beniBuild(`apps/micro/beni/${v}`, `out/micro-${v.toLowerCase()}-rel`, true);
}

if (!process.argv.includes("--no-solid")) {
  const solid = join(here, "apps/solid2");
  if (!existsSync(join(solid, "node_modules"))) run("npm", ["install", "--no-audit", "--no-fund"], solid);
  rmSync(join(here, "out/solid2"), { recursive: true, force: true });
  for (const entry of ["bench", "static", "helpers"]) {
    const r = spawnSync("npx", ["vite", "build", "--logLevel", "warn"], { cwd: solid, stdio: "inherit", env: { ...process.env, ENTRY: entry } });
    if (r.status !== 0) throw new Error(`vite build ${entry}: exit ${r.status}`);
  }
  const solid1 = join(here, "apps/solid1");
  if (!existsSync(join(solid1, "node_modules"))) run("npm", ["install", "--no-audit", "--no-fund"], solid1);
  rmSync(join(here, "out/solid1"), { recursive: true, force: true });
  run("npx", ["rollup", "-c", "--environment", "production", "--silent"], solid1);
}

const version = spawnSync(beni, ["version"], { encoding: "utf8" }).stdout.trim();
writeFileSync(join(here, "out/built.json"), JSON.stringify({ beni: version, at: new Date().toISOString() }, null, 2));
console.log(`built with ${version}`);
readFileSync(join(here, "out/beni-dev/_main.mjs"));
