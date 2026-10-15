// The playground's page (docs/design/playground.md §4.1): a source, a
// compile 300 ms after the last edit, the compiler's diagnostics, the
// program in a sandboxed frame (§5), and the emitted JavaScript.
//
// The compiler runs in `worker.js`. One compile runs at a time; a source
// edited while one runs waits, and only the newest waiting source is
// compiled. A result that is not the newest source's is shown but not run.

const samples = {
  "browser-direct": "samples/browser-direct/Counter.beni",
  node: "samples/node/Print.beni",
};

const $ = (id) => document.getElementById(id);
const source = $("source");
const platform = $("platform");
const status = $("status");
const diagnostics = $("diagnostics");
const output = $("console");
const fileList = $("file");
const code = $("code");
let frame = $("frame");

// A failure the page did not foresee (a file that does not load) is shown,
// not caught.
const fail = (reason) => {
  setStatus("The playground failed", "error");
  diagnostics.textContent = reason instanceof Error ? (reason.stack ?? String(reason)) : String(reason);
};
addEventListener("error", (event) => fail(event.error ?? event.message));
addEventListener("unhandledrejection", (event) => fail(event.reason));

const worker = new Worker(new URL("worker.js", import.meta.url), { type: "module" });
const frameScript = text("frame.js");

// The source of each platform, so that a switch keeps what was written.
const sources = {};
let shown = platform.value;
let nextId = 1;
let newest = 0;
let busy = false;
let waiting = null;
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

function compileSoon() {
  clearTimeout(timer);
  timer = setTimeout(compile, 300);
}

function compile() {
  newest = nextId;
  nextId += 1;
  waiting = { id: newest, platform: platform.value, source: source.value };
  pump();
}

function pump() {
  if (busy || waiting === null) return;
  busy = true;
  worker.postMessage(waiting);
  waiting = null;
  setStatus("Compiling…");
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

function show(result) {
  if (result.crash !== null) {
    const stack = result.crash.startsWith("RangeError");
    setStatus(stack ? "The compiler ran out of stack" : "The compiler crashed", "error");
    diagnostics.textContent = `${result.stderr}${result.crash}\n`;
    return;
  }
  diagnostics.textContent = result.stderr === "" ? "No problems." : result.stderr;
  showFiles(result.files);
  const ms = `${Math.round(result.ms)} ms`;
  if (result.code !== 0) {
    setStatus(result.code === 1 ? `Errors (${ms})` : `beni exited ${result.code} (${ms})`, "error");
    return;
  }
  setStatus(result.stderr === "" ? `Built in ${ms}` : `Built in ${ms}, with warnings`, "ok");
  if (result.id === newest) runProgram(result.files);
}

worker.addEventListener("message", ({ data }) => {
  if (data.kind === "ready") {
    setStatus(`Compiler loaded in ${Math.round(data.ms)} ms`);
    return;
  }
  busy = false;
  if (data.kind === "defect") {
    setStatus("The playground failed", "error");
    diagnostics.textContent = data.message;
  } else {
    show(data);
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
  });
}

fileList.addEventListener("change", () => {
  code.textContent = emitted[fileList.value] ?? "";
});

source.addEventListener("input", compileSoon);

platform.addEventListener("change", async () => {
  sources[shown] = source.value;
  shown = platform.value;
  source.value = sources[shown] ?? (await text(samples[shown]));
  compile();
});

source.value = await text(samples[platform.value]);
compile();
