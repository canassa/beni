// `npm run build-prod`: the table app built by beni for one platform, with
// `--release`, into dist/. The compiler is $BENI, or `beni` on PATH; it is
// not an npm package, so js-framework-benchmark's `npm ci` cannot fetch it.
//
//   node build.mjs <platform>
//
// beni-tea/build.mjs and beni-direct/build.mjs are the same file, one per
// entry because the benchmark wants each entry self-contained: keep them equal.

import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";

const platform = process.argv[2];
if (platform === undefined) throw new Error("usage: node build.mjs <platform>");
const beni = process.env.BENI ?? "beni";

rmSync("dist", { recursive: true, force: true });
const r = spawnSync(beni, ["build", `--platform=${platform}`, "--release", "--no-cache", "--no-source-maps", "--out=dist", "src/Main.beni"], { stdio: "inherit" });
if (r.error !== undefined) throw r.error;
process.exit(r.status ?? 1);
