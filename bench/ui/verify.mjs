// Correctness before timing (research 29 §1.7): drives every button of every
// subject in headless Chrome and asserts the DOM after each.
//
//   node verify.mjs [--subjects=a,b] [--chrome=<path>]

import { launch } from "./lib/cdp.mjs";
import { serve } from "./lib/serve.mjs";
import { subjects as all } from "./lib/subjects.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const wanted = arg("subjects", null)?.split(",") ?? null;
const subjects = wanted === null ? all : all.filter((s) => wanted.includes(s.name));

const rows = `document.querySelectorAll("tbody > tr")`;
const cell = (r, c) => `document.querySelector("tbody > tr:nth-of-type(${r}) > td:nth-of-type(${c})").textContent.trim()`;

const checks = [
  ["run", `${rows}.length === 1000 && ${cell(1, 1)} === "1"`, "1 000 rows, the first id 1"],
  [
    null,
    `(() => { const tr = document.querySelector("tbody > tr"); const tds = tr.children; return tds.length === 4 && tds[0].className === "col-md-1" && tds[1].className === "col-md-4" && tds[1].firstElementChild.tagName === "A" && tds[2].querySelector("a > span.glyphicon.glyphicon-remove") !== null && tds[3].className === "col-md-6"; })()`,
    "the row's shape",
  ],
  ["//tbody/tr[2]/td[2]/a", `document.querySelector("tbody > tr:nth-of-type(2)").classList.contains("danger") && document.querySelectorAll("tbody > tr.danger").length === 1`, "row 2 selected, alone"],
  ["swaprows", `${cell(2, 1)} === "999" && ${cell(999, 1)} === "2"`, "rows 2 and 999 swapped"],
  ["swaprows", `${cell(2, 1)} === "2" && ${cell(999, 1)} === "999"`, "and swapped back"],
  ["update", `${cell(991, 2)}.endsWith(" !!!") && ${cell(1, 2)}.endsWith(" !!!") && !${cell(2, 2)}.endsWith(" !!!")`, "every 10th label updated"],
  ["//tbody/tr[4]/td[3]/a/span[1]", `${rows}.length === 999 && ${cell(4, 1)} === "5"`, "row 4 removed"],
  ["add", `${rows}.length === 1999 && ${cell(1999, 1)} === "2000"`, "1 000 appended"],
  ["clear", `${rows}.length === 0`, "cleared"],
  ["runlots", `${rows}.length === 10000 && ${cell(1, 1)} === "2001"`, "10 000 created"],
];

const browser = await launch({ chrome: arg("chrome", undefined) });
const { server, origin } = await serve(subjects);
let failed = 0;
for (const s of subjects) {
  const page = await browser.newPage(`${origin}/s/${s.name}/`);
  const errors = [];
  const off = browser.on((m) => {
    if (m.sessionId === page.sessionId && m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description);
  });
  const results = [];
  try {
    await page.waitFor(`document.getElementById("run") !== null`);
    for (const [click, expect, what] of checks) {
      if (click !== null) await page.click(click.startsWith("//") ? `document.evaluate(${JSON.stringify(click)}, document, null, 9, null).singleNodeValue` : `document.getElementById(${JSON.stringify(click)})`);
      try {
        await page.waitFor(expect, 5000);
        results.push(`ok ${what}`);
      } catch {
        results.push(`FAIL ${what}`);
        failed++;
      }
    }
  } catch (e) {
    results.push(`FAIL ${e.message}`);
    failed++;
  }
  off();
  if (errors.length) {
    results.push(`FAIL exceptions: ${errors.join("; ")}`);
    failed++;
  }
  console.log(`${s.name}: ${results.join(", ")}`);
  await page.close();
}
server.close();
await browser.close();
console.log(`${browser.version}: ${failed === 0 ? "all subjects pass" : `${failed} failures`}`);
process.exit(failed === 0 ? 0 : 1);
