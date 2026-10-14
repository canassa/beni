// Investigation only: the exact table warm-up followed by one profiled
// update, every candidate in rotated order. No profiled timing is a verdict.
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadavg } from "node:os";
import { launch, sleep } from "../../lib/cdp.mjs";
import { root, serve } from "../../lib/serve.mjs";
import { subjects as allSubjects } from "../../lib/subjects.mjs";
import { benchmarks } from "../../lib/benchmarks.mjs";
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const names = ["vanillajs", "solid1", "solid2", "beni-release", "beni-direct-release", "p3"];
const subjects = names.map((name) => allSubjects.find((s) => s.name === name));
const bench = benchmarks.find((b) => b.id === "03_update10th1k_x16");
const n = Number(arg("n", "20"));
const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", "2-5,8-11") });
const { server, origin } = await serve(allSubjects);
const out = arg("out", fileURLToPath(new URL("profile-update.json", import.meta.url)));
const result = { purpose: "sampling profiles, not comparison timings", n, rate: 1, intervalRequestedUs: 25, chrome: browser.version, node: process.version, started: new Date().toISOString(), cpu: execSync("uname -m").toString().trim(), compiler: JSON.parse(readFileSync(root + "/out/built.json")), profiles: [] };
try {
  for (let i = 0; i < n; i++) for (let k = 0; k < subjects.length; k++) {
    const subject = subjects[(i + k) % subjects.length];
    const page = await browser.newPage(`${origin}/s/${subject.name}/`);
    try {
      await bench.init(page);
      await sleep(100);
      await page.eval("window.gc && window.gc()");
      const box = await page.locate(bench.target);
      await sleep(50);
      await page.send("Profiler.enable");
      await page.send("Profiler.setSamplingInterval", { interval: 25 });
      await page.send("Profiler.start");
      await page.press(box);
      await sleep(500);
      const { profile } = await page.send("Profiler.stop");
      if (!(await page.eval(bench.done))) throw new Error("update postcondition failed");
      for (const node of profile.nodes) node.callFrame.url = node.callFrame.url.replace(origin, "");
      result.profiles.push({ subject: subject.name, iteration: i, load: loadavg()[0], profile });
      console.log(`${subject.name} #${i}: ${profile.samples.length} samples`);
    } finally {
      await page.close();
    }
  }
  result.finished = new Date().toISOString();
  writeFileSync(out, JSON.stringify(result));
} finally {
  server.close();
  await browser.close();
}
