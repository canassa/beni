// The roots of `ownership-checker.md` §30.7 O1's audit, which
// `ownership-v2.md` §7.2's whole-corpus verdict diff dumps under both
// checkers (`bench/ownership-everywhere.mjs --diff`). The list is the audit
// driver of #210 (comment 6349617458), the one O1 was accepted on: the
// positive corpus and its platform variants, the Workers corpus, the
// development Debug fixtures, every example, the live benchmark apps, core,
// every production and test platform surface, the schema prototype's
// platform, the positive depth boundaries, and every ownership fixture whose
// golden has no refused or pending list line and no limit.
//
// Each root is `{ name, argv }`: `beni dump --stage=ownership
// --ownership-everywhere ...argv` dumps it.

import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const entries = (p) => readdirSync(p, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));

/// The `.beni` files below `p`, its own `platform/` and hidden directories left out.
function files(p) {
  return entries(p).flatMap((e) => {
    if (e.isDirectory()) return e.name === "platform" || e.name.startsWith(".") || e.name === "node_modules" ? [] : files(join(p, e.name));
    return e.name.endsWith(".beni") ? [join(p, e.name)] : [];
  });
}

/// Every `beni.json` below `p`.
function manifests(p) {
  return entries(p).flatMap((e) => {
    if (e.isDirectory()) return ["node_modules", ".beni-cache", ".git", "out", "dist"].includes(e.name) ? [] : manifests(join(p, e.name));
    return e.name === "beni.json" ? [join(p, e.name)] : [];
  });
}

export function o1Roots(repo, scratch) {
  const programs = [];
  function project(p, platform, extra = [], dumpOnly = false) {
    let dir = p;
    let src = p.endsWith(".beni") ? [p] : files(p);
    let root = [];
    if (existsSync(join(p, "platform", "beni.json"))) platform = join(p, "platform");
    // A page that drives a program kept elsewhere names its sources.
    const named = join(p, "_expected.sources");
    if (existsSync(named)) {
      const paths = readFileSync(named, "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
      dir = mkdtempSync(join(scratch, "source-"));
      for (const path of paths) cpSync(resolve(repo, path), dir, { recursive: true });
      src = files(dir);
    }
    if (platform && !platform.includes("/") && existsSync(join(repo, "tests/platforms", platform, "beni.json"))) platform = join(repo, "tests/platforms", platform);
    if (!p.endsWith(".beni")) root = [`--root=${dir}`];
    programs.push({ name: relative(repo, p), platform, extra, dumpOnly, src, root, dumpPath: dir });
  }
  function group(dir, platform, extra = [], dumpOnly = false) {
    for (const e of entries(dir)) {
      const p = join(dir, e.name);
      if (e.name.endsWith(".beni")) project(p, platform, extra, dumpOnly);
      else if (!e.isDirectory()) continue;
      else if (e.name === "core") group(p, platform, ["--core"], true);
      else if (e.name === "inline") group(p, "browser-inline", extra, dumpOnly);
      else if (e.name === "markup") group(p, "html", extra, dumpOnly);
      else if (e.name === "dom" || e.name === "split") group(p, "browser", extra, dumpOnly);
      else if (e.name === "tea") group(p, "browser-tea", extra, dumpOnly);
      else if (e.name === "app" || e.name === "release") group(p, platform, extra, dumpOnly);
      else project(p, platform, extra, dumpOnly);
    }
  }
  group(join(repo, "tests/corpus/run"), "node");
  for (const e of entries(join(repo, "tests/corpus/browser"))) {
    const p = join(repo, "tests/corpus/browser", e.name);
    if (["dom", "tea", "inline"].includes(e.name)) group(p, { dom: "browser", tea: "browser-tea", inline: "browser-inline" }[e.name]);
    else if (e.isDirectory() || e.name.endsWith(".beni")) project(p, join(repo, "tests/platforms/page"));
  }
  group(join(repo, "tests/corpus/workers"), "cloudflare");
  // These Debug fixtures are positive development programs.
  group(join(repo, "tests/corpus/build/bad-release"), "node");
  for (const kind of ["check/good", "emit", "dispatch", "typekeys", "repkeys", "writes"]) group(join(repo, "tests/corpus", kind), kind === "writes" ? "browser-tea" : "node");
  for (const m of manifests(join(repo, "examples"))) {
    const build = JSON.parse(readFileSync(m, "utf8")).build;
    if (!build) continue;
    const dir = mkdtempSync(join(scratch, "example-"));
    for (const path of build.paths) cpSync(resolve(dirname(m), path), dir, { recursive: true });
    programs.push({ name: relative(repo, dirname(m)), platform: build.platform, extra: [], dumpOnly: false, dumpPath: dir, src: files(dir), root: [`--root=${dir}`] });
  }
  for (const n of ["NoEditing", "NoRouting", "NoStorage", "Sandbox"]) project(join(repo, "bench/todomvc/apps/beni", `${n}.beni`), "browser-tea");
  for (const n of ["beni/Main.beni", "micro/beni/Components", "micro/beni/Helpers", "micro/beni/Inline"]) project(join(repo, "bench/ui/apps", n), "browser-tea");
  project(join(repo, "bench/jfb/frameworks/keyed/beni-tea/src"), "browser-tea");
  project(join(repo, "bench/corpus"), "node");
  project(join(repo, "bench/schema-prototype/platform"), join(repo, "bench/schema-prototype/platform"), [], true);
  project(join(repo, "core"), null, [], true);
  for (const m of [...manifests(join(repo, "platforms")), ...manifests(join(repo, "tests/platforms"))]) {
    const p = dirname(m);
    project(p, p, [], true);
  }
  // Live applications added since the original benchmark app inventory.
  for (const n of ["Fibers", "Plain"]) project(join(repo, "bench/fiber/apps", `${n}.beni`), "node");
  project(join(repo, "bench/websocket/server"), "node");
  project(join(repo, "bench/websocket/page"), "browser-tea");
  project(join(repo, "bench/minify/empty-page/src"), "browser-tea");
  project(join(repo, "bench/size-apps/ApiAndRoutes.beni"), "browser-tea");
  // Positive depth boundaries, and the ownership goldens with no refused or
  // pending list line, platform variants included.
  for (const e of entries(join(repo, "tests/corpus/check/depth"))) if (e.name.endsWith("Ok.beni")) project(join(repo, "tests/corpus/check/depth", e.name), "node");
  function ownership(dir, core = false) {
    for (const e of entries(dir)) {
      if (e.name === "core" && e.isDirectory()) {
        ownership(join(dir, e.name), true);
        continue;
      }
      if (!e.isDirectory() && !e.name.endsWith(".beni")) continue;
      const p = join(dir, e.name);
      const base = e.isDirectory() ? join(p, "_expected") : p.slice(0, -5);
      const tokens = existsSync(`${base}.platform`) ? readFileSync(`${base}.platform`, "utf8").split(/\s+/).filter((t) => t && !t.startsWith("#")) : ["node"];
      for (const token of tokens) {
        const golden = [`${base}.${token.split("/").at(-1)}.ownership`, `${base}.ownership`].find(existsSync);
        if (!golden) throw Error(`missing ownership golden ${base} ${token}`);
        const lines = readFileSync(golden, "utf8").split("\n");
        if (lines.some((l) => { const m = l.match(/^\s+\d+:\d+ (.*): (rejected|pending)(?: |:|$)/); return m && !m[1].startsWith("update "); })) continue;
        if (lines.some((l) => /ownership limit|limit exceeded/.test(l))) continue;
        project(p, token.replace(/\+everywhere$/, ""), core ? ["--core"] : [], core);
        programs.at(-1).name += ` [${token}]`;
      }
    }
  }
  ownership(join(repo, "tests/corpus/ownership"));
  for (const p of programs) {
    // One file is dumped as that file: a directory's walk skips a symbolic link.
    if (p.src.length === 1) p.dumpPath = p.src[0];
    if (p.name === "core" || p.name.startsWith("platforms/") || p.name.startsWith("tests/platforms/")) p.root = [];
    if (p.name === "core") p.dumpPath = "core";
    if (p.dumpOnly && p.platform === p.dumpPath) p.root = [];
  }
  return programs.map((p) => {
    const flags = [...(p.platform ? [`--platform=${p.platform}`] : []), ...p.extra, ...p.root];
    // Type-surface core fixtures are dumped with no runtime platform.
    if (p.dumpOnly && p.extra.includes("--core")) {
      const i = flags.findIndex((f) => f.startsWith("--platform="));
      if (i >= 0) flags.splice(i, 1);
    }
    return { name: p.name, argv: [...flags, p.dumpPath] };
  });
}
