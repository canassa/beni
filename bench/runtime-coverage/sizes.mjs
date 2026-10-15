// Research 103's before/after: the release bundle of each app on both
// platforms, brotli 11 with the size hint (research 97/99/101/102's
// protocol), built by BENI (default zig-out/bin/beni) into OUT.
//
//   BENI=… OUT=zig-out/sizes-after node bench/runtime-coverage/sizes.mjs [--json=<file>]

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { size } from "../output-size/lib.mjs";

const repo = resolve(import.meta.dirname, "../..");
const beni = process.env.BENI ?? join(repo, "zig-out/bin/beni");
const out = resolve(repo, process.env.OUT ?? "zig-out/sizes");
const subjects = {
  Conduit: { src: "examples/conduit/src" },
  TodoMVC: { src: "tests/corpus/browser/direct/TodoMVC.beni" },
  Sternhalma: { src: "examples/sternhalma/src", root: true },
  BikeWars: { src: "examples/bike-wars/src", root: true },
  Table: { src: "bench/ui/apps/beni/Main.beni" },
};
const result = {};
for (const [name, s] of Object.entries(subjects)) {
  for (const p of ["tea", "direct"]) {
    const dir = join(out, `${name}-${p}`);
    execFileSync(beni, ["build", `--platform=browser-${p}`, "--release", "--no-cache", `--out=${dir}`, ...(s.root ? [`--root=${s.src}`] : []), s.src], { cwd: repo, stdio: "pipe" });
    result[`${name}-${p}`] = size(readFileSync(join(dir, "_main.mjs"), "utf8"));
    console.log(`${name.padEnd(11)} ${p.padEnd(7)} raw ${String(result[`${name}-${p}`].raw).padStart(7)}  brotli ${String(result[`${name}-${p}`].brotli).padStart(6)}`);
  }
}
const json = process.argv.find((a) => a.startsWith("--json="))?.slice(7);
if (json) writeFileSync(json, JSON.stringify(result, null, 1) + "\n");
