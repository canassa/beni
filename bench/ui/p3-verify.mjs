// The differential check of research 60's P3 pages: each P3 page and the
// beni page it stands for are driven through the same steps in headless
// Chrome, and after every step the two documents must be equal, node for
// node: elements, attributes, text and every input's value. Comments are
// skipped (beni marks slots with them), runs of adjacent text are joined,
// and an empty `class` attribute equals none. An exception on either page
// fails the case.
//
//   node p3-verify.mjs [--cases=holes:10,table] [--chrome=<path>]
//
// After `node build.mjs` (the table app) and `node scaling.mjs --build-only`
// with the points named below.

import { existsSync } from "node:fs";
import { join } from "node:path";
import { launch } from "./lib/cdp.mjs";
import { root, serve } from "./lib/serve.mjs";
import { subjects as tableSubjects } from "./lib/subjects.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;

const byId = (id) => `document.getElementById(${JSON.stringify(id)})`;
const x = (path) => `document.evaluate(${JSON.stringify(path)}, document, null, 9, null).singleNodeValue`;
// Steps: a real click, K synthetic clicks in one task, or text typed into
// the k-th input (its value set, then an `input` event).
const click = (finder) => ({ click: finder });
const burst = (id, k) => ({ eval: `(() => { const n = ${byId(id)}; for (let i = 0; i < ${k}; i++) n.click(); return true; })()` });
const type = (k, text) => ({
  eval: `(() => { const n = document.querySelectorAll("input")[${k}]; n.value = ${JSON.stringify(text)}; n.dispatchEvent(new Event("input", { bubbles: true })); return true; })()`,
});

const scaling = (sweep, p, steps) => ({
  id: `${sweep}:${p}`,
  beni: { name: `${sweep}-${p}.beni`, kind: "beni", dir: `scaling/${sweep}/${p}/beni-dev` },
  p3: { name: `${sweep}-${p}.p3`, kind: "script", src: `/out/scaling/${sweep}/${p}/p3.js`, module: true },
  ready: `${byId("go")} !== null`,
  steps,
});
const go = click(byId("go"));
const cases = [
  scaling("holes", 10, [go, go, burst("go", 5), go]),
  scaling("holes", 1000, [go, burst("go", 30), go]),
  scaling("holes", 10000, [go, go]),
  scaling("rows", 30000, [go, click(byId("swap")), go, click(byId("swap")), click(byId("swap")), burst("go", 3), burst("swap", 3)]),
  scaling("live", 10000, [go, type(3, "hello"), go, type(3, ""), type(9999, "last"), burst("go", 2)]),
  scaling("depth", 128, [go, go, burst("go", 4)]),
  {
    id: "table",
    beni: tableSubjects.find((s) => s.name === "beni"),
    p3: tableSubjects.find((s) => s.name === "p3"),
    ready: `${byId("run")} !== null`,
    steps: [
      click(byId("run")),
      click(x("//tbody/tr[2]/td[2]/a")),
      click(byId("swaprows")),
      click(byId("swaprows")),
      click(byId("update")),
      click(x("//tbody/tr[4]/td[3]/a/span[1]")),
      click(x("//tbody/tr[7]/td[3]/a")),
      click(byId("add")),
      click(x("//tbody/tr[1500]/td[2]/a")),
      burst("swaprows", 3),
      burst("update", 2),
      click(byId("run")),
      click(byId("clear")),
      click(byId("clear")),
      click(byId("runlots")),
      click(x("//tbody/tr[9999]/td[2]/a")),
      click(byId("swaprows")),
      click(byId("add")),
      click(byId("run")),
    ],
  },
];

const serialise = `(() => {
  const ser = (n) => {
    if (n.nodeType !== 1) return "";
    if (n.tagName === "SCRIPT" || n.id === "burst") return "";
    const attrs = [...n.attributes].filter((a) => !(a.name === "class" && a.value === "")).map((a) => a.name + "=" + JSON.stringify(a.value)).sort().join(" ");
    let out = "<" + n.tagName + (attrs ? " " + attrs : "") + (n.tagName === "INPUT" ? " .value=" + JSON.stringify(n.value) : "") + ">";
    let text = null;
    for (const c of n.childNodes) {
      if (c.nodeType === 3) text = (text ?? "") + c.data;
      else if (c.nodeType === 1) {
        if (text !== null) out += JSON.stringify(text);
        text = null;
        out += ser(c);
      }
    }
    if (text !== null) out += JSON.stringify(text);
    return out + "</" + n.tagName + ">";
  };
  return ser(document.body);
})()`;

const wanted = arg("cases", null)?.split(",") ?? null;
const chosen = cases.filter((c) => (wanted === null || wanted.includes(c.id)) && (c.beni.dir === undefined || existsSync(join(root, "out", c.beni.dir))));
const browser = await launch({ chrome: arg("chrome", undefined), taskset: arg("taskset", null) });
const { server, origin } = await serve(chosen.flatMap((c) => [c.beni, c.p3]));
const settle = "new Promise((done) => setTimeout(() => done(true), 0))";

const open = async (subject, ready) => {
  const page = await browser.newPage(`${origin}/s/${subject.name}/`);
  const errors = [];
  const off = browser.on((m) => {
    if (m.sessionId === page.sessionId && m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
  });
  await page.send("Runtime.enable");
  await page.waitFor(ready);
  return { page, errors, off };
};

let failed = 0;
for (const c of chosen) {
  const a = await open(c.beni, c.ready);
  const b = await open(c.p3, c.ready);
  const results = [];
  const compare = async (label) => {
    await a.page.eval(settle);
    await b.page.eval(settle);
    const [da, db] = [await a.page.eval(serialise), await b.page.eval(serialise)];
    if (da === db) return true;
    let i = 0;
    while (i < da.length && da[i] === db[i]) i++;
    results.push(`FAIL after ${label}: differs at ${i}: beni …${da.slice(Math.max(0, i - 80), i + 80)}… p3 …${db.slice(Math.max(0, i - 80), i + 80)}…`);
    return false;
  };
  let ok = await compare("mount");
  for (let s = 0; ok && s < c.steps.length; s++) {
    const step = c.steps[s];
    for (const p of [a.page, b.page]) {
      if (step.click !== undefined) await p.click(step.click);
      else await p.eval(step.eval);
    }
    ok = await compare(`step ${s + 1} (${step.click ?? step.eval.slice(0, 60)})`);
  }
  a.off();
  b.off();
  if (a.errors.length > 0 || b.errors.length > 0) {
    results.push(`FAIL exceptions: beni ${a.errors.join("; ")} p3 ${b.errors.join("; ")}`);
    ok = false;
  }
  if (!ok) failed++;
  console.log(`${c.id}: ${ok ? `ok, ${c.steps.length} steps equal` : results.join("\n  ")}`);
  await a.page.close();
  await b.page.close();
}
server.close();
await browser.close();
console.log(`${browser.version}: ${failed === 0 ? "every P3 page equals its beni page after every step" : `${failed} cases differ`}`);
process.exit(failed === 0 ? 0 : 1);
