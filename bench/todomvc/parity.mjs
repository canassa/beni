#!/usr/bin/env node
// Which TodoMVC features each subject size.mjs measures really has: every
// built bundle is loaded into a happy-dom page (tests/browser/happy-dom.mjs,
// the browser corpus's DOM) in a process of its own and driven through
// todomvc.com's features, and the table says which worked. It checks the
// features column of research 51's size table; it is not a test suite and
// is in no gate.
//
//   node bench/todomvc/parity.mjs        (after size.mjs has built out/)

import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dom = join(here, "../../tests/browser/happy-dom.mjs");
const out = join(here, "out");

const features = ["add", "counter", "toggle", "filter by hash", "filter at start", "edit", "toggle all", "clear completed", "persistence"];

if (process.argv[2] === "--page") {
  // One subject, in this process: print a JSON object of feature → bool.
  const [, , , bundle, seedHash] = process.argv;
  const { GlobalWindow } = await import(pathToFileURL(dom).href);
  const window = new GlobalWindow({ url: `http://localhost:8080/${seedHash}` });
  for (const [key, d] of Object.entries(Object.getOwnPropertyDescriptors(window))) {
    if (["constructor", "undefined", "NaN", "global", "globalThis", "console", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "queueMicrotask", "crypto", "performance"].includes(key)) continue;
    const own = Object.getOwnPropertyDescriptor(globalThis, key);
    if (own !== undefined && own.value !== undefined && own.value === d.value) continue;
    if (d.value === window) d.value = globalThis;
    Object.defineProperty(globalThis, key, { ...d, configurable: true });
  }
  for (const m of ["addEventListener", "removeEventListener", "dispatchEvent"]) globalThis[m] = window[m].bind(window);
  document.body.innerHTML = '<section class="todoapp"></section><div id="main"></div>';
  const settle = () => new Promise((r) => setTimeout(r, 30));
  const result = {};
  const errors = [];
  process.on("uncaughtException", (e) => errors.push(String(e)));
  try {
    await import(pathToFileURL(bundle).href);
  } catch (e) {
    errors.push(String(e));
  }
  await settle();
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => [...document.querySelectorAll(s)];
  const rows = () => $$(".todo-list li");
  const count = () => ($(".todo-count")?.textContent ?? "").replace(/\s+/g, " ").trim();
  const key = (el, k, code) => {
    for (const type of ["keydown", "keyup"]) el.dispatchEvent(new KeyboardEvent(type, { key: k, keyCode: code, bubbles: true, cancelable: true }));
  };
  const add = async (text) => {
    const input = $(".new-todo");
    input.value = text;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    key(input, "Enter", 13);
    await settle();
  };
  const go = async (hash) => {
    history.replaceState(null, "", hash);
    window.dispatchEvent(new PopStateEvent("popstate"));
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    await settle();
  };
  const selected = () => $(".filters a.selected")?.textContent.trim() ?? "";
  // The page opened at #/active; footers that only exist with todos need two.
  await add("first");
  await add("second");
  result["filter at start"] = selected() === "Active";
  await go("#/");
  result.add = rows().length === 2 && rows().some((r) => r.textContent.includes("second"));
  result.counter = count().startsWith("2 items left");
  const firstToggle = $$(".todo-list li .toggle").find((t) => t.closest("li").textContent.includes("first"));
  firstToggle?.click();
  await settle();
  result.toggle = count().startsWith("1 item left");
  await go("#/completed");
  const completed = rows().length;
  await go("#/active");
  const active = rows().length;
  await go("#/");
  result["filter by hash"] = completed === 1 && active === 1 && rows().length === 2;
  const label = $$(".todo-list li label").find((l) => l.textContent.includes("second"));
  label?.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
  await settle();
  const edit = $(".todo-list li .edit");
  if (edit) {
    edit.value = "renamed";
    edit.dispatchEvent(new Event("input", { bubbles: true }));
    key(edit, "Enter", 13);
    await settle();
  }
  result.edit = edit !== null && rows().some((r) => r.textContent.includes("renamed")) && $(".todo-list li .edit") === null;
  const stored = JSON.stringify(Object.fromEntries(Object.keys(localStorage).map((k) => [k, localStorage.getItem(k)])));
  result.persistence = stored.includes("first");
  $(".toggle-all")?.click();
  await settle();
  result["toggle all"] = count().startsWith("0 items left");
  $(".clear-completed")?.click();
  await settle();
  result["clear completed"] = rows().length === 0;
  process.stdout.write(JSON.stringify({ result, errors }));
  process.exit(0);
}

const subjects = readdirSync(out)
  .filter((d) => d !== "beni-dev")
  .sort();
const tmp = mkdtempSync(join(tmpdir(), "todomvc-parity-"));
console.log(`| subject | ${features.join(" | ")} |`);
console.log(`|---|${features.map(() => ":-:").join("|")}|`);
for (const s of subjects) {
  const dir = join(out, s);
  const file = readdirSync(dir).find((f) => /\.m?js$/.test(f) && f !== "_manifest.txt");
  // An `.mjs` copy, so every bundle is imported as a module whatever its
  // name says.
  const copy = join(tmp, `${s}.mjs`);
  copyFileSync(join(dir, file), copy);
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "--page", copy, "#/active"], { encoding: "utf8" });
  let cells;
  try {
    const { result, errors } = JSON.parse(r.stdout);
    cells = features.map((f) => (result[f] ? "yes" : "**no**"));
    if (errors.length) cells.push(`errors: ${errors.join("; ").slice(0, 120)}`);
  } catch {
    cells = [`failed: ${(r.stderr || r.stdout).split("\n").slice(0, 3).join(" ").slice(0, 200)}`];
  }
  console.log(`| ${s} | ${cells.join(" | ")} |`);
}
rmSync(tmp, { recursive: true, force: true });
