// Research 56: the static-heavy page (gen-micro.mjs's Solid 2 inline page)
// on Solid 1, built as rollup.config.js builds the table benchmark's entry,
// into out/match/static/solid1.js. Solid 1 renders a signal write at once,
// so its `__flush` does nothing.
//
//   node build-static.mjs     (from apps/solid1)

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const here = new URL(".", import.meta.url).pathname;
const src = readFileSync(join(here, "../solid2/src/static.jsx"), "utf8")
  .replace("on Solid 2, inline", "on Solid 1, inline (research 56)")
  .replace('import { createSignal, flush } from "solid-js";\nimport { render } from "@solidjs/web";', 'import { createSignal } from "solid-js";\nimport { render } from "solid-js/web";\nconst flush = () => {};');
if (src.includes("@solidjs/web")) throw new Error("build-static: the Solid 2 page's imports moved");
mkdirSync(join(here, "gen"), { recursive: true });
writeFileSync(join(here, "gen/static.jsx"), src);
const out = join(here, "../../out/match/static");
mkdirSync(out, { recursive: true });
const list = join(out, "entries.json");
writeFileSync(list, JSON.stringify([[join(here, "gen/static.jsx"), join(out, "solid1.js")]]));
const r = spawnSync("npx", ["rollup", "-c", "rollup.scaling.config.js", "--silent"], { cwd: here, stdio: "inherit", env: { ...process.env, SCALING_ENTRIES: list } });
if (r.status !== 0) throw new Error(`rollup: exit ${r.status}`);
