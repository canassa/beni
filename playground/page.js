// The playground's page (docs/design/playground.md §4): the editor, with the
// program's CSS in a second tab (§4.6), a compile 300 ms after the last edit,
// the compiler's diagnostics in the editor and in a list, the program in a
// sandboxed frame (§5) with its CSS, the emitted JavaScript, the `types` and
// `ownership` dumps, the samples and the shareable link.
//
// The compiler runs in `worker.js`, one command at a time. Every edit of the
// source or the CSS, and a change of platform, makes a new version of the
// input; a result of an older version is dropped, and the newest version is
// compiled once the worker is free. A dump runs only while its tab is open.
// The compiler never reads the CSS: a new frame gets it (§4.6). A defect of
// the playground is not run again for the version it failed on, so a
// failure that repeats is shown once and not retried without end; a newer
// version still runs.
import { createCodeView, createEditor, markDiagnostics, replaceText, reveal, showCode, textOf } from "./editor.js";
import { decode, encode } from "./share.js";
import { srcdoc } from "./srcdoc.js";

const $ = (id) => document.getElementById(id);
const status = $("status");
const platform = $("platform");
const sampleList = $("sample");
const diagnosticsView = $("diagnostics");
const output = $("console");
const fileList = $("file");
// The emitted JavaScript, in a read-only view with the JavaScript grammar.
const code = createCodeView($("code"));
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
// the command the worker runs, with the version it was posted for.
let version = 0;
const shown = { build: -1, types: -1, ownership: -1 };
let running = null;
let runningVersion = -1;
let ready = false;
// A note for the status of the next build (a damaged link), so that the
// build does not hide it.
let notice = "";
// The editors of the source and the CSS, made once the first source is
// known.
let editor = null;
let cssEditor = null;
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
  return document.querySelector("[data-tab][aria-selected=true]").dataset.tab;
}

// Show the tab `tab` of its tab list, and its panel, and hide the others.
function select(tab) {
  for (const other of tab.parentElement.querySelectorAll("[role=tab]")) {
    const selected = other === tab;
    other.setAttribute("aria-selected", String(selected));
    $(other.dataset.tab ?? other.dataset.file).hidden = !selected;
  }
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
  runningVersion = version;
  worker.postMessage({ id: version, command, platform: platform.value, source: textOf(editor) });
  if (command === "build") setStatus("Compiling…");
}

// A new version of the input. A person's change also clears the fragment:
// the address holds a program only while the editor holds it.
function edited(byUser) {
  version += 1;
  if (byUser && location.hash !== "") history.replaceState(null, "", location.pathname + location.search);
  for (const pane of [$("types-text"), $("ownership-text")]) pane.classList.add("stale");
  clearTimeout(timer);
  timer = setTimeout(() => {
    timer = 0;
    pump();
  }, 300);
}

// The console keeps the last `consoleLines` pieces of output: a program
// that prints in a loop does not grow the page without end (§8).
const consoleLines = 2000;

function append(line, kind = "") {
  if (output.childElementCount >= consoleLines) output.firstElementChild.remove();
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
  showCode(code, emitted[fileList.value] ?? "");
}

// A new frame with `files` and the CSS pane's text (§4.6), which is the
// CSS of the version these files were built from: an edit of it makes a
// newer version, whose build drops this one.
async function runProgram(files) {
  const script = await frameScript;
  const fresh = document.createElement("iframe");
  fresh.id = "frame";
  fresh.title = frame.title;
  fresh.setAttribute("sandbox", "allow-scripts");
  fresh.srcdoc = srcdoc(files, textOf(cssEditor), script);
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
      if (d.span.file === "Main.beni") {
        title.addEventListener("click", () => {
          select(document.querySelector('[data-file="editor"]'));
          reveal(editor, d.span);
        });
      }
      return [title, preOf(d.message)];
    }),
  );
}

function showBuild(result) {
  if (result.crash !== null) {
    setStatus(result.crashKind === "stack" ? "The compiler ran out of stack" : "The compiler crashed", "error");
    markDiagnostics(editor, []);
    diagnosticsView.replaceChildren(preOf(`${result.stderr}${result.crash}
`));
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
  setStatus(`${list.length === 0 ? `Built in ${ms}` : `Built in ${ms}, with warnings`}${notice}`, "ok");
  notice = "";
  runProgram(result.files);
}

function showDump(result) {
  const view = $(`${result.command}-text`);
  view.classList.remove("stale");
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
    // For a measurement (`bench/playground/chrome.mjs`): the status moves on
    // at once.
    document.documentElement.dataset.compilerLoadedMs = String(Math.round(data.ms));
    pump();
    return;
  }
  if (data.kind === "defect") {
    // The command failed in the host: it is not run again for the version
    // it was posted for. A defect carries no id; an edit while it ran made
    // a newer version, which is compiled.
    shown[running] = runningVersion;
    running = null;
    setStatus("The playground failed", "error");
    diagnosticsView.replaceChildren(preOf(data.message));
    // Runs only a newer version, if an edit made one: the failed one is
    // shown.
    pump();
    return;
  }
  running = null;
  try {
    if (data.id === version) {
      shown[data.command] = data.id;
      if (data.command === "build") showBuild(data);
      else showDump(data);
    }
  } finally {
    // Not a catch: an exception above still reaches the page's listeners,
    // and the queue still moves on.
    pump();
  }
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

for (const tab of document.querySelectorAll("[data-tab]")) {
  tab.addEventListener("click", () => {
    select(tab);
    pump();
  });
}

// The source's tabs (§4.6): `Main.beni` and `style.css`.
for (const tab of document.querySelectorAll("[data-file]")) {
  tab.addEventListener("click", () => select(tab));
}

fileList.addEventListener("change", () => {
  showCode(code, emitted[fileList.value] ?? "");
});

platform.addEventListener("change", () => edited(true));

// The samples (§4.3, §4.6): `samples/index.json` lists each one's name,
// platform and file, and its CSS file if it has one.
const samples = JSON.parse(await text("samples/index.json"));
sampleList.replaceChildren(...samples.map((s, i) => new Option(s.name, String(i))), new Option("(shared)", "shared"));

// The newest sample asked for: a slower fetch of an older one is dropped.
let sampleAsked = 0;

async function loadSample(index) {
  const asked = ++sampleAsked;
  const sample = samples[index];
  const [source, css] = await Promise.all([text(sample.path), sample.css === undefined ? "" : text(sample.css)]);
  if (asked !== sampleAsked) return;
  platform.value = sample.platform;
  replaceText(editor, source);
  replaceText(cssEditor, css);
  // Also when the text did not change: the platform may have. Choosing a
  // sample is a person's change.
  edited(true);
}

sampleList.addEventListener("change", () => {
  if (sampleList.value !== "shared") loadSample(Number(sampleList.value));
});

// The shareable link (§4.5, §4.6): the source and the CSS in the fragment.
$("share").addEventListener("click", async () => {
  const fragment = await encode(platform.value, textOf(editor), textOf(cssEditor));
  history.replaceState(null, "", `#${fragment}`);
  sampleList.value = "shared";
  // Only a secure page has a clipboard to write.
  if (navigator.clipboard === undefined) {
    setStatus("The address bar holds the link", "ok");
    return;
  }
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
cssEditor = createEditor($("css-editor"), "", edited, "css");
if (shared !== null) {
  if ([...platform.options].some((o) => o.value === shared.platform)) platform.value = shared.platform;
  sampleList.value = "shared";
  replaceText(editor, shared.source);
  replaceText(cssEditor, shared.css);
  // Also when the source is empty, which changes nothing in the editor. The
  // link stays in the address until a person changes the program or its
  // CSS.
  edited(false);
} else {
  if (location.hash !== "") notice = " (the link held no program, so this is the first sample)";
  sampleList.value = "0";
  await loadSample(0);
}
