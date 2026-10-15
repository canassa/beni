// Research 103's coverage runs: every real app's corpus script on both
// browser platforms' `--release` builds, in headless Chrome, with V8's
// precise block coverage (`Profiler.startPreciseCoverage`, `detailed: true`).
//
//   node bench/runtime-coverage/run.mjs [--apps=ConduitEditor,…] [--platforms=tea,direct]
//
// BENI selects the compiler (default zig-out/bin/beni); CHROME the browser
// (default google-chrome-stable). Output: zig-out/runtime-coverage/<app>-<p>/
// with `_main.mjs`, its release map, `coverage.json` (the target's
// `takePreciseCoverage` at the end of the script) and `transcript.txt`, which
// must equal the fixture's golden (checked here: a coverage run whose page
// did something else is not evidence).
//
// The corpus driver (`tests/browser/driver.mjs`) runs the scripts unchanged:
// this file writes a copy with two edits — start coverage before the page
// loads, take it before the target closes — so a script means exactly what
// it means in `zig build test-browser`.

import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repo = resolve(import.meta.dirname, "../..");
const work = resolve(repo, process.env.WORK ?? "zig-out/runtime-coverage");
const beni = process.env.BENI ?? join(repo, "zig-out/bin/beni");
const chrome = process.env.CHROME ?? "google-chrome-stable";
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;

// app → [sources, steps, golden dir]
const corpus = "tests/corpus/browser/direct";
export const apps = {
  ConduitEditor: { src: "examples/conduit/src", dir: `${corpus}/ConduitEditor` },
  ConduitReader: { src: "examples/conduit/src", dir: `${corpus}/ConduitReader` },
  ConduitTour: { src: "examples/conduit/src", dir: `${corpus}/ConduitTour` },
  TodoMVC: { src: `${corpus}/TodoMVC.beni`, steps: `${corpus}/TodoMVC.steps`, expected: `${corpus}/TodoMVC` },
  Sternhalma: { src: "examples/sternhalma/src", dir: `${corpus}/Sternhalma`, root: true },
  BikeWars: { src: "examples/bike-wars/src", dir: `${corpus}/BikeWars`, root: true },
  // bench/ui's table app: no golden; the script must run to its end.
  Table: { src: "bench/ui/apps/beni/Main.beni", steps: "bench/runtime-coverage/table.steps", expected: null },
};

const pick = arg("apps", Object.keys(apps).join(",")).split(",");
const platforms = arg("platforms", "tea,direct").split(",");

// The patched driver.
const driverSrc = readFileSync(join(repo, "tests/browser/driver.mjs"), "utf8");
const enable = `await send("Page.enable", {}, sessionId);`;
const close = `await send("Target.closeTarget", { targetId });`;
if (!driverSrc.includes(enable) || !driverSrc.includes(close)) throw new Error("driver.mjs changed: update the coverage patch");
const patched = driverSrc
  .replace(enable, `${enable}\n  await send("Profiler.enable", {}, sessionId);\n  await send("Profiler.startPreciseCoverage", { callCount: true, detailed: true }, sessionId);`)
  .replace(close, `writeFileSync(process.env.COVERAGE_OUT, JSON.stringify(await send("Profiler.takePreciseCoverage", {}, sessionId)));\n      ${close}`)
  .replaceAll(`"./compile-cache.mjs"`, JSON.stringify(join(repo, "tests/browser/compile-cache.mjs")));
mkdirSync(work, { recursive: true });
const driver = join(work, "driver-coverage.mjs");
writeFileSync(driver, patched);

// One headless Chrome for every run.
const profile = mkdtempSync(join(tmpdir(), "runtime-coverage-"));
const child = spawn("taskset", ["-c", "8-23", chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run", `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"], { stdio: "ignore" });
const portFile = join(profile, "DevToolsActivePort");
for (let i = 0; i < 400 && !(existsSync(portFile) && readFileSync(portFile, "utf8").includes("\n")); i++) await new Promise((r) => setTimeout(r, 50));
const [port, path] = readFileSync(portFile, "utf8").trim().split("\n");
const endpoint = `ws://127.0.0.1:${port}${path}`;

let failed = 0;
try {
  for (const name of pick) {
    const a = apps[name];
    for (const p of platforms) {
      const out = join(work, `${name}-${p}`);
      rmSync(out, { recursive: true, force: true });
      execFileSync(beni, ["build", `--platform=browser-${p}`, "--release", "--allow-debug", "--source-maps", "--no-cache", `--out=${out}`, ...(a.root ? [`--root=${a.src}`] : []), a.src], { cwd: repo, stdio: "inherit" });
      const steps = a.steps ?? `${a.dir}/_expected.steps`;
      const goldenBase = a.expected ?? `${a.dir}/_expected`;
      // A difference the design specifies for browser-tea, or for Chrome, is its own golden.
      const golden =
        a.expected === null
          ? null
          : [p === "tea" && `${goldenBase}.tea-chrome-expected`, p === "tea" && `${goldenBase}.tea-release-expected`, p === "tea" && `${goldenBase}.tea-expected`, `${goldenBase}.chrome-expected`, `${goldenBase}.release-expected`, `${goldenBase}.expected`].find((f) => f && existsSync(join(repo, f)));
      // Every page here is a `browser/direct/` page: its transcript leaves comments out.
      const r = spawnSync("node", [driver, `--chrome=${endpoint}`, "--no-comments", join(out, "_main.mjs"), join(repo, steps)], {
        cwd: repo,
        env: { ...process.env, COVERAGE_OUT: join(out, "coverage.json") },
        encoding: "utf8",
        maxBuffer: 1 << 28,
      });
      writeFileSync(join(out, "transcript.txt"), r.stdout);
      const same = r.status === 0 && (golden === null || r.stdout === readFileSync(join(repo, golden), "utf8"));
      if (!same) failed++;
      console.log(`${name} ${p}: exit ${r.status}, transcript ${same ? "matches" : "DIFFERS from"} ${golden ?? "(no golden)"}${r.stderr ? `\n${r.stderr.slice(0, 2000)}` : ""}`);
    }
  }
} finally {
  child.kill();
}
process.exit(failed === 0 ? 0 : 1);
