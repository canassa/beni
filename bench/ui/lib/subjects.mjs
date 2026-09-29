// The table benchmark's subjects. `build.mjs` produces what they load.
// `out/extra-subjects.json`, when present, adds more (an array of the same
// objects): experiments on a copy of an output directory, never committed.

import { existsSync, readFileSync } from "node:fs";

const extra = new URL("../out/extra-subjects.json", import.meta.url);

export const subjects = [
  { name: "beni", kind: "beni", dir: "beni-dev" },
  { name: "beni-release", kind: "beni", dir: "beni-rel" },
  { name: "solid2", kind: "solid", entry: "bench" },
  { name: "p2", kind: "script", body: "static", src: "/apps/p2/bench.js" },
  { name: "vanillajs", kind: "script", body: "static", src: "/out/jfb/Main.js" },
  ...(existsSync(extra) ? JSON.parse(readFileSync(extra, "utf8")) : []),
];
