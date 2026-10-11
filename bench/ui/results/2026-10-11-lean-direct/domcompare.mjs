// Lean-direct measurement: drive a long op sequence on several subjects and
// compare the whole <tbody> after every op. Exact against beni-direct-release
// (same seeded labels); against vanillajs on everything but label words
// (class, id, row shape, the " !!!" suffix count).
import { launch, sleep } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";
import { subjects as all } from "./lib/subjects.mjs";
const names = (process.argv[2] ?? "lean-direct,lean-direct-html,beni-direct-release,vanillajs").split(",");
const subjects = all.filter((s) => names.includes(s.name));
const btn = (id) => `document.getElementById("${id}")`;
const label = (r) => `document.querySelector("tbody > tr:nth-of-type(${r}) > td:nth-of-type(2) > a")`;
const remove = (r) => `document.querySelector("tbody > tr:nth-of-type(${r}) > td:nth-of-type(3) > a > span")`;
const ops = [
  ["run", btn("run")], ["select 2", label(2)], ["swap", btn("swaprows")], ["swap", btn("swaprows")],
  ["update", btn("update")], ["remove 4", remove(4)], ["add", btn("add")], ["select 5", label(5)],
  ["swap", btn("swaprows")], ["update", btn("update")], ["remove 1", remove(1)], ["select 999", label(999)],
  ["swap", btn("swaprows")], ["remove 998", remove(998)], ["select 3", label(3)], ["select 3", label(3)],
  ["update", btn("update")], ["run", btn("run")], ["swap", btn("swaprows")], ["select 2", label(2)],
  ["remove 2", remove(2)], ["add", btn("add")], ["update", btn("update")], ["remove 1997", remove(1997)],
  ["clear", btn("clear")], ["add", btn("add")], ["select 1", label(1)], ["update", btn("update")],
  ["runlots", btn("runlots")], ["swap", btn("swaprows")], ["select 9000", label(9000)], ["remove 9000", remove(9000)],
  ["update", btn("update")], ["add", btn("add")], ["clear", btn("clear")], ["run", btn("run")],
];
const snap = `JSON.stringify([...document.querySelector("tbody").children].map((tr) => {
  const c = tr.getAttribute("class") ?? ""; const tds = tr.children;
  const shape = tr.outerHTML.replace(/<tr[^>]*>/, "<tr>").replace(/<a>[^<]*<\\/a>/, "<a>L</a>").replace(/(<td class="col-md-1">)[^<]*(<\\/td>)/, "$1I$2");
  return [c, tds[0].textContent, tds[1].textContent, shape, tr.parentNode.tagName];
}))`;
const browser = await launch({ chrome: process.env.CHROME ?? "google-chrome" });
const { server, origin } = await serve(subjects);
const runs = {};
for (const s of subjects) {
  const page = await browser.newPage(`${origin}/s/${s.name}/`);
  const errors = [];
  browser.on((m) => { if (m.sessionId === page.sessionId && m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description); });
  await page.waitFor(`document.getElementById("run") !== null`);
  runs[s.name] = [];
  for (const [what, finder] of ops) {
    await page.click(finder);
    await sleep(30);
    runs[s.name].push(JSON.parse(await page.eval(snap)));
  }
  if (errors.length) console.log(`${s.name}: EXCEPTIONS ${errors.join("; ")}`);
  await page.close();
}
server.close();
await browser.close();
const ref = runs["beni-direct-release"], van = runs["vanillajs"];
let bad = 0;
for (const name of names) {
  if (name === "beni-direct-release" || name === "vanillajs") continue;
  ops.forEach(([what], k) => {
    const a = runs[name][k];
    const exact = JSON.stringify(a) === JSON.stringify(ref[k]);
    const loose = (rs) => JSON.stringify(rs.map(([c, id, l, shape]) => [c, id, (l.match(/ !!!/g) ?? []).length, shape]));
    const vs = loose(a) === loose(van[k]);
    if (!exact || !vs) { bad++; console.log(`${name} after #${k} ${what}: vs direct ${exact ? "same" : "DIFFERENT"}, vs vanilla ${vs ? "same" : "DIFFERENT"} (${a.length} rows)`); }
  });
  console.log(`${name}: ${ops.length} ops compared, rows per op ${runs[name].map((r) => r.length).join(" ")}`);
}
// direct vs vanilla too, as a control
ops.forEach(([what], k) => {
  const loose = (rs) => JSON.stringify(rs.map(([c, id, l, shape]) => [c, id, (l.match(/ !!!/g) ?? []).length, shape]));
  if (loose(ref[k]) !== loose(van[k])) console.log(`control: direct vs vanilla differ after #${k} ${what}`);
});
console.log(bad === 0 ? "ALL SAME" : `${bad} differences`);
for (const k of [5, 6]) {
  const loose = (r) => JSON.stringify([r[0], r[1], (r[2].match(/ !!!/g) ?? []).length, r[3]]);
  const a = ref[k], v = van[k];
  for (let i = 0; i < Math.max(a.length, v.length); i++) if (loose(a[i] ?? ["-", "", "", ""]) !== loose(v[i] ?? ["-", "", "", ""])) { console.log(k, i, loose(a[i] ?? ["-","","",""]), loose(v[i] ?? ["-","","",""])); break; }
}
