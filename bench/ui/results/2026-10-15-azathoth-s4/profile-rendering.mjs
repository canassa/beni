// Diagnostic profiles of the missed rendering endpoints. Every available
// candidate shares the same five warm-up clicks, then one profiled click.
// The sampling interval and profiles are evidence, not comparison timings.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadavg } from "node:os";
import { launch, sleep } from "../../lib/cdp.mjs";
import { root, serve } from "../../lib/serve.mjs";
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const specs = [
  { sweep: "live", p: 10000, id: "tick", initial: 0, p3: true },
  { sweep: "helperRows", p: 10000, id: "tick", initial: 0 },
  { sweep: "derived", p: 100000, id: "tick", initial: 0 },
  { sweep: "depth", p: 128, id: "v", initial: 0, p3: true },
  { sweep: "width", p: 1024, id: "changed", initial: 512 },
];
const subjects = (spec) => {
  const dir = `scaling/${spec.sweep}/${spec.p}`;
  const list = [
    { subject: "vanillajs", kind: "script", src: `/out/${dir}/vanilla.js` },
    { subject: "solid1", kind: "solid", src: `/out/${dir}/solid1.js`, module: false },
    { subject: "solid2", kind: "solid", src: `/out/${dir}/solid2.js` },
    { subject: "beni-release", kind: "beni", dir: `${dir}/beni-rel` },
    { subject: "beni-direct-release", kind: "beni", dir: `${dir}/beni-direct-rel` },
    ...(spec.p3 ? [{ subject: "p3", kind: "script", src: `/out/${dir}/p3.js`, module: true }] : []),
  ];
  return list.map((s) => ({ ...s, name: `profile.${spec.sweep}.${s.subject}` }));
};
const n = Number(arg("n", "20"));
const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", "2-5,8-11") });
const { server, origin } = await serve(specs.flatMap(subjects));
const out = arg("out", fileURLToPath(new URL("profile-rendering.json", import.meta.url)));
const result = { purpose: "sampling profiles, not comparison timings", n, rate: 1, intervalRequestedUs: 25, chrome: browser.version, node: process.version, started: new Date().toISOString(), compiler: JSON.parse(readFileSync(root + "/out/built.json")), profiles: [] };
try {
  for (const spec of specs) {
    const list = subjects(spec);
    const done = (k) => `document.getElementById(${JSON.stringify(spec.id)})?.textContent === ${JSON.stringify(String(spec.initial + k))}`;
    for (let i = 0; i < n; i++) for (let k = 0; k < list.length; k++) {
      const subject = list[(i + k) % list.length];
      const page = await browser.newPage(`${origin}/s/${subject.name}/`);
      try {
        await page.waitFor(done(0), 60000);
        for (let j = 1; j <= 5; j++) {
          await page.click('document.getElementById("go")');
          await page.waitFor(done(j), 60000);
        }
        await sleep(50);
        await page.eval("window.gc && window.gc()");
        const box = await page.locate('document.getElementById("go")');
        await sleep(20);
        await page.send("Profiler.enable");
        await page.send("Profiler.setSamplingInterval", { interval: 25 });
        await page.send("Profiler.start");
        await page.press(box);
        await sleep(300);
        const { profile } = await page.send("Profiler.stop");
        if (!(await page.eval(done(6)))) throw new Error("profile postcondition failed");
        for (const node of profile.nodes) node.callFrame.url = node.callFrame.url.replace(origin, "");
        result.profiles.push({ sweep: spec.sweep, param: spec.p, subject: subject.subject, iteration: i, load: loadavg()[0], profile });
        console.log(`${spec.sweep} ${subject.subject} #${i}: ${profile.samples.length} samples`);
      } finally {
        await page.close();
      }
    }
    writeFileSync(out, JSON.stringify(result));
  }
  result.finished = new Date().toISOString();
  writeFileSync(out, JSON.stringify(result));
} finally {
  server.close();
  await browser.close();
}
