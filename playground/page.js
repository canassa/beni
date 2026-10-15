// The playground's page (docs/design/playground.md §4): the editor, a
// compile 300 ms after the last edit, the compiler's diagnostics in the
// editor and in a list, the program in a sandboxed frame (§5), the emitted
// JavaScript, the `types` and `ownership` dumps, the samples and the
// shareable link.
//
// The compiler runs in `worker.js`, one command at a time. Every edit, and a
// change of platform, makes a new version of the input; a result of an older
// version is dropped, and the newest version is compiled once the worker is
// free. A dump runs only while its tab is open.
import { createEditor, markDiagnostics, replaceText, reveal, textOf } from "./editor.js";
import { decode, encode } from "./share.js";

const $ = (id) => document.getElementById(id);
const status = $("status");
const platform = $("platform");
const sampleList = $("sample");
const diagnosticsView = $("diagnostics");
const output = $("console");
const fileList = $("file");
const code = $("code");
let frame = $("frame");

// A failure the page did not foresee (a file that does not load) is shown,
// not caught.
const fail = (reason) => {
  setStatus("The playground failed", "error");
  diagnosticsView.replaceChildren(preOf(reason instanceof Error ? (reason.stack ?? String(reason)) : String(reason)));
};
addEventListener("error", (event) => fail(event.error ?? event.message));
addEventListener("unhandledrejection", (event) => fail(event.reason));

const worker = new Worker(new URL("worker.js", import.meta.url), { type: "module" });
const frameScript = text("frame.js");

// The input's version, the version each command's shown result is of, and
// the command the worker runs.
let version = 0;
const shown = { build: -1, types: -1, ownership: -1 };
let running = null;
let ready = false;
// The editor, made once the first source is known.
let editor = null;
let timer = 0;
let emitted = {};

async function text(path) {
  const response = await fetch(new URL(path, import.meta.url));
  if (!response.ok) throw new Error(`cannot load ${path}: HTTP ${response.status}`);
  return response.text();
}

function setStatus(message, kind = "") {
  status.textContent = message;
  status.className = kind;
}

function preOf(content) {
  const pre = document.createElement("pre");
  pre.textContent = content;
  return pre;
}

function selectedTab() {
  return document.querySelector("[role=tab][aria-selected=true]").dataset.tab;
}

// The next command for the newest version: the build first, then the dump
// whose tab is open.
function nextCommand() {
  if (shown.build !== version) return "build";
  const tab = selectedTab();
  if ((tab === "types" || tab === "ownership") && shown[tab] !== version) return tab;
  return null;
}

function pump() {
  if (!ready || editor === null || running !== null || timer !== 0) return;
  const command = nextCommand();
  if (command === null) return;
  running = command;
  worker.postMessage({ id: version, command, platform: platform.value, source: textOf(editor) });
  if (command === "build") setStatus("Compiling…");
}

function edited() {
  version += 1;
  clearTimeout(timer);
  timer = setTimeout(() => {
    timer = 0;
    pump();
  }, 300);
}

function append(line, kind = "") {
  const span = document.createElement("span");
  span.textContent = line;
  if (kind !== "") span.className = kind;
  output.append(span);
}

function showFiles(files) {
  emitted = files;
  const selected = fileList.value;
  fileList.replaceChildren(
    ...Object.keys(files)
      .filter((path) => path.endsWith(".mjs"))
      .sort()
      .map((path) => new Option(path, path)),
  );
  if (Object.hasOwn(files, selected)) fileList.value = selected;
  else if (Object.hasOwn(files, "Main.mjs")) fileList.value = "Main.mjs";
  code.textContent = emitted[fileList.value] ?? "";
}

async function runProgram(files) {
  const script = await frameScript;
  // The files go into the frame as JSON in a `<script>` element: no `<`
  // may close it early.
  const json = JSON.stringify(files).replaceAll("<", "\\u003c");
  const fresh = document.createElement("iframe");
  fresh.id = "frame";
  fresh.title = frame.title;
  fresh.setAttribute("sandbox", "allow-scripts");
  fresh.srcdoc = [
    '<!doctype html><html><head><meta charset="utf-8">',
    `<script id="beni-files" type="application/json">${json}</script>`,
    `<script>${script}</script>`,
    "</head><body></body></html>",
  ].join("");
  output.replaceChildren();
  frame.replaceWith(fresh);
  frame = fresh;
}

// The diagnostics of a run that exited 0 or 1: JSON, as `--diagnostics=json`
// writes them. Exit 2 is a usage or I/O failure, written as text.
function diagnosticsOf(result) {
  if (result.code === 2 || result.stderr.trim() === "") return [];
  return JSON.parse(result.stderr);
}

function showDiagnostics(list) {
  markDiagnostics(editor, list.filter((d) => d.span.file === "Main.beni"));
  if (list.length === 0) {
    const none = document.createElement("p");
    none.textContent = "No problems.";
    diagnosticsView.replaceChildren(none);
    return;
  }
  diagnosticsView.replaceChildren(
    ...list.flatMap((d) => {
      const title = document.createElement("button");
      title.type = "button";
      title.className = `diagnostic ${d.severity}`;
      title.textContent = `${d.title} — ${d.span.file}:${d.span.start.line}:${d.span.start.col}`;
      if (d.span.file === "Main.beni") title.addEventListener("click", () => reveal(editor, d.span));
      return [title, preOf(d.message)];
    }),
  );
}

function showBuild(result) {
  if (result.crash !== null) {
    const stack = result.crash.startsWith("RangeError");
    setStatus(stack ? "The compiler ran out of stack" : "The compiler crashed", "error");
    markDiagnostics(editor, []);
    diagnosticsView.replaceChildren(preOf(`${result.stderr}${result.crash}\n`));
    return;
  }
  const ms = `${Math.round(result.ms)} ms`;
  if (result.code === 2) {
    setStatus(`beni exited 2 (${ms})`, "error");
    markDiagnostics(editor, []);
    diagnosticsView.replaceChildren(preOf(result.stderr));
    return;
  }
  const list = diagnosticsOf(result);
  showDiagnostics(list);
  showFiles(result.files);
  if (result.code !== 0) {
    const errors = list.filter((d) => d.severity === "error").length;
    setStatus(`${errors} ${errors === 1 ? "error" : "errors"} (${ms})`, "error");
    return;
  }
  setStatus(list.length === 0 ? `Built in ${ms}` : `Built in ${ms}, with warnings`, "ok");
  runProgram(result.files);
}

function showDump(result) {
  const view = $(`${result.command}-text`);
  if (result.crash !== null) {
    view.textContent = `${result.stderr}${result.crash}\n`;
    return;
  }
  const failed = result.code !== 0 ? "\n-- The program has errors: see the diagnostics. --\n" : "";
  view.textContent = `${result.stdout}${failed}`;
}

worker.addEventListener("message", ({ data }) => {
  if (data.kind === "ready") {
    ready = true;
    setStatus(`Compiler loaded in ${Math.round(data.ms)} ms`);
    pump();
    return;
  }
  running = null;
  if (data.kind === "defect") {
    setStatus("The playground failed", "error");
    diagnosticsView.replaceChildren(preOf(data.message));
  } else if (data.id === version) {
    shown[data.command] = data.id;
    if (data.command === "build") showBuild(data);
    else showDump(data);
  }
  pump();
});

// What the program in the frame prints, logs and throws.
addEventListener("message", (event) => {
  if (event.source !== frame.contentWindow || event.data === null || typeof event.data !== "object") return;
  const { beni: kind, text: line } = event.data;
  if (kind === "stdout") append(line);
  else if (kind === "console") append(`${line}\n`);
  else if (kind === "error") append(`${line}\n`, "error");
  else if (kind === "exit" && line !== "0") append(`exit code ${line}\n`, "error");
  // The entry module and every module it imports loaded.
  else if (kind === "loaded") frame.dataset.loaded = "true";
});

for (const tab of document.querySelectorAll("[role=tab]")) {
  tab.addEventListener("click", () => {
    for (const other of document.querySelectorAll("[role=tab]")) {
      const selected = other === tab;
      other.setAttribute("aria-selected", String(selected));
      $(other.dataset.tab).hidden = !selected;
    }
    pump();
  });
}

fileList.addEventListener("change", () => {
  code.textContent = emitted[fileList.value] ?? "";
});

platform.addEventListener("change", edited);

// The samples (§4.3): `samples/index.json` lists each one's name, platform
// and file.
const samples = JSON.parse(await text("samples/index.json"));
sampleList.replaceChildren(...samples.map((s, i) => new Option(s.name, String(i))), new Option("(shared)", "shared"));

async function loadSample(index) {
  const sample = samples[index];
  platform.value = sample.platform;
  replaceText(editor, await text(sample.path));
  history.replaceState(null, "", location.pathname + location.search);
}

sampleList.addEventListener("change", () => {
  if (sampleList.value !== "shared") loadSample(Number(sampleList.value));
});

// The shareable link (§4.5): the source in the fragment.
$("share").addEventListener("click", async () => {
  const fragment = await encode(platform.value, textOf(editor));
  history.replaceState(null, "", `#${fragment}`);
  sampleList.value = "shared";
  await navigator.clipboard.writeText(location.href).then(
    () => setStatus("Link copied", "ok"),
    (e) => {
      // A page may not write the clipboard (no focus, or no permission):
      // the address bar holds the link.
      if (e instanceof DOMException && e.name === "NotAllowedError") setStatus("The address bar holds the link", "ok");
      else throw e;
    },
  );
});

const shared = await decode(location.hash);
editor = createEditor($("editor"), "", edited);
if (shared !== null) {
  if ([...platform.options].some((o) => o.value === shared.platform)) platform.value = shared.platform;
  sampleList.value = "shared";
  replaceText(editor, shared.source);
} else {
  if (location.hash !== "") setStatus("The link holds no program", "error");
  sampleList.value = "0";
  await loadSample(0);
}
