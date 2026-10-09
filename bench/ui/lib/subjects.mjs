// The table benchmark's subjects. `build.mjs` produces what they load.
// `out/extra-subjects.json`, when present, adds more (an array of the same
// objects): experiments on a copy of an output directory, never committed.

import { existsSync, readFileSync } from "node:fs";

const extra = new URL("../out/extra-subjects.json", import.meta.url);

export const subjects = [
  { name: "beni", kind: "beni", dir: "beni-dev" },
  { name: "beni-release", kind: "beni", dir: "beni-rel" },
  // The same sources built for `browser-direct` (browser-direct.md §12.2);
  // skipped, with the compiler's reason, while its slices cannot build them.
  { name: "beni-direct", kind: "beni", dir: "beni-direct-dev" },
  { name: "beni-direct-release", kind: "beni", dir: "beni-direct-rel" },
  { name: "solid2", kind: "solid", entry: "bench" },
  { name: "solid1", kind: "solid", src: "/out/solid1/main.js", module: false },
  { name: "p2", kind: "script", body: "static", src: "/apps/p2/bench.js" },
  // Research 60: message-indexed rendering by hand; imports core from out/beni-dev.
  { name: "p3", kind: "script", src: "/apps/p3/bench.js", module: true },
  { name: "vanillajs", kind: "script", body: "static", src: "/out/jfb/Main.js" },
  ...(existsSync(extra) ? JSON.parse(readFileSync(extra, "utf8")) : []),
];
