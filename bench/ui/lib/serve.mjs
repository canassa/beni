// The static server every subject is loaded from: files under bench/ui/,
// the benchmark's stylesheet under /css/, and each subject's page generated
// at /s/<name>/. Cross-origin isolated (COOP/COEP), so `performance.now()`
// has its fine resolution in the in-page measurements.

import { readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

export const root = fileURLToPath(new URL("..", import.meta.url));

const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };

const head = (title) =>
  `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>${title}</title><link href="/css/currentStyle.css" rel="stylesheet"/></head>`;

// The body js-framework-benchmark's vanillajs page ships: the jumbotron, the
// six buttons and an empty `<tbody id="tbody">`.
const staticBody = () => readFileSync(join(root, "lib/static-body.html"), "utf8");

export function subjectPage(subject) {
  switch (subject.kind) {
    case "beni":
      return `${head(subject.name)}<body><script type="module" src="/out/${subject.dir}/_main.mjs"></script></body></html>`;
    // A beni program started by hand rather than by its entry file, so the
    // page can time the mount and reach the runtime's `flush`. A release
    // build is one scope-hoisted file that starts itself (backend.md §9), so
    // there the page preloads it — fetched and compiled — and times its
    // evaluation, which is the mount plus the program's top-level values,
    // and reads `flush` from its one export.
    case "beni-micro":
      return `${head(subject.name)}<body><script type="module">
const dir = "/out/${subject.dir}/";
const entry = await (await fetch(dir + "_main.mjs")).text();
const imported = /import\\s*\\{\\s*(\\S+?)\\s*\\}\\s*from\\s*"\\.\\/Main\\.mjs"/.exec(entry);
if (imported === null) {
  const link = document.createElement("link");
  link.rel = "modulepreload";
  link.href = dir + "_main.mjs";
  await new Promise((done) => { link.onload = done; document.head.append(link); });
  const t0 = performance.now();
  const one = await import(dir + "_main.mjs");
  window.__mount = performance.now() - t0;
  window.__flush = one.flush;
} else {
  const data = JSON.parse(/start\\((.*)\\);/.exec(entry)[1]);
  // \`run\` and \`flush\` are the runtime module's (\`Rt.beni\`), \`start\` the file's.
  const rt = await import(dir + "_platform/_browser/runtime.foreign.mjs");
  const loop = await import(dir + "_platform/_browser/Rt.mjs");
  const main = (await import(dir + "Main.mjs"))[imported[1]];
  const t0 = performance.now();
  rt.start(data);
  loop.Rt$run(main);
  window.__mount = performance.now() - t0;
  window.__flush = loop.Rt$flush;
}
</script></body></html>`;
    case "solid":
      // Solid 2 is an ES module per page; Solid 1 is js-framework-benchmark's IIFE.
      return `${head(subject.name)}<body><div id="main"></div><script ${subject.module === false ? "" : 'type="module" '}src="${subject.src ?? `/out/solid2/${subject.entry}.js`}"></script></body></html>`;
    case "script":
      return `${head(subject.name)}<body>${subject.body === "static" ? staticBody() : ""}<script ${subject.module ? 'type="module" ' : ""}src="${subject.src}"></script></body></html>`;
  }
  throw new Error(`unknown subject kind ${subject.kind}`);
}

export function serve(subjects, port = 0) {
  const byName = new Map(subjects.map((s) => [s.name, s]));
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    const headers = { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp", "Cache-Control": "no-store" };
    const m = /^\/s\/([^/]+)\/$/.exec(url.pathname);
    if (m !== null && byName.has(m[1])) {
      res.writeHead(200, { ...headers, "Content-Type": "text/html" });
      res.end(subjectPage(byName.get(m[1])));
      return;
    }
    let path = decodeURIComponent(url.pathname);
    if (path.startsWith("/css/")) path = `/out${path}`;
    const file = normalize(join(root, path));
    if (!file.startsWith(root)) {
      res.writeHead(403).end();
      return;
    }
    try {
      if (!statSync(file).isFile()) throw new Error();
      res.writeHead(200, { ...headers, "Content-Type": types[extname(file)] ?? "application/octet-stream" });
      res.end(readFileSync(file));
    } catch {
      res.writeHead(404, headers).end();
    }
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` })));
}
