#!/usr/bin/env node
// TodoMVC's size: beni's against Solid 1, Solid 2, Svelte 5 and Svelte 4,
// every subject a production build, and where beni's release bytes go
// (research 51). Sizes follow `backend.md` §13: brotli 11 first, gzip -9
// second, raw a diagnostic; each is of every JavaScript file the page
// loads, concatenated in sorted path order (bench/ui/sizes.mjs's method).
// CSS is not measured for any subject, nor todomvc-common's `base.js`,
// which tastejs's pages load beside the app and which is no framework's.
//
//   node bench/todomvc/size.mjs [--beni=<path>] [--no-build] [--json]
//
// `--beni` is the compiler (default zig-out/bin/beni); `--no-build` measures
// what out/ holds; `--json` prints one JSON line per subject instead of the
// tables. The npm projects under apps/ are installed from their lockfiles
// the first time (`npm ci`), and their node_modules are git-ignored. A full
// run, builds included, takes about half a minute.
//
// The subjects, and the features each has (todomvc.com's specification:
// add, toggle, toggle-all, edit, delete, clear completed, the counter, the
// filters with hash routing, localStorage persistence):
//
//   beni        tests/corpus/browser/tea/TodoMVC.beni, `--release
//               --platform=browser-tea`: everything but editing
//   beni-full   apps/beni/Full.beni: the same plus editing (the whole spec)
//   solid1-full solidjs/solid-todomvc's src/index.tsx, verbatim, through
//               its own Rollup config (babel-preset-solid, terser defaults):
//               the whole spec but the filter read at start
//   solid1-parity  the same cut to beni's features (no editing; the filter
//               read at start)
//   solid2-*    the official Solid 1 app ported to Solid 2.0.0-rc.9 (there
//               is no official Solid 2 TodoMVC), Vite with Vite's defaults
//   svelte5-asis   tastejs/todomvc's examples/svelte (Svelte 5), verbatim
//               but for its stylesheet imports: no persistence, and the
//               filter is not read at start
//   svelte5-full   asis plus localStorage and the filter read at start
//   svelte5-parity full without editing
//   svelte4-*   the same three from tastejs's Svelte 4 example (7c64d8f4)
//
// Two instruments then take beni's bytes apart:
//
// - **By module.** The development build (one `.mjs` per module, names
//   kept) is scope-hoisted by Rollup and minified by terser with source
//   maps, and every minified byte is charged to the module it came from.
//   That bundle is a PROXY for the release file, which has no map
//   (`--release --source-maps` is refused): its total is printed beside the
//   release's so the reader can judge it. Each group's cost is given alone
//   and leave-one-out (the bundle's brotli minus the bundle's brotli
//   without that group's bytes — the bytes the rest does not explain).
// - **By feature.** Release builds of apps/beni's variants, each the
//   TodoMVC with one capability taken out, priced against the TodoMVC:
//   exact release bytes, not a proxy.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { createRequire, SourceMap } from "node:module";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../..");
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const beni = arg("beni", join(repo, "zig-out/bin/beni"));
const build = !process.argv.includes("--no-build");
const json = process.argv.includes("--json");
const out = join(here, "out");
const apps = join(here, "apps");

const run = (cmd, args, cwd, env = {}) => {
  const r = spawnSync(cmd, args, { cwd, stdio: ["ignore", "inherit", "inherit"], env: { ...process.env, ...env } });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} (in ${cwd}): exit ${r.status}`);
};

// ---- Building ----------------------------------------------------------------

const beniBuild = (source, dir, flags = ["--release"]) => {
  rmSync(dir, { recursive: true, force: true });
  run(beni, ["build", "--platform=browser-tea", "--no-cache", ...flags, `--out=${dir}`, source], repo);
};

const npmApps = {
  solid1: { entries: ["full", "parity"], cmd: (e) => ["npx", ["rollup", "-c", "--environment", "production", "--silent"], { ENTRY: e }] },
  solid2: { entries: ["full", "parity"], cmd: (e) => ["npx", ["vite", "build", "--logLevel", "warn"], { ENTRY: e }] },
  svelte5: { entries: ["asis", "full", "parity"], cmd: (e) => ["npx", ["vite", "build", "--logLevel", "warn"], { ENTRY: e }] },
  svelte4: { entries: ["asis", "full", "parity"], cmd: (e) => ["npx", ["vite", "build", "--logLevel", "warn"], { ENTRY: e }] },
};

const beniVariants = readdirSync(join(apps, "beni"))
  .filter((f) => f.endsWith(".beni"))
  .sort()
  .map((f) => f.slice(0, -5));

if (build) {
  mkdirSync(out, { recursive: true });
  beniBuild("tests/corpus/browser/tea/TodoMVC.beni", join(out, "beni"));
  beniBuild("tests/corpus/browser/tea/TodoMVC.beni", join(out, "beni-dev"), ["--no-source-maps"]);
  for (const v of beniVariants) beniBuild(`bench/todomvc/apps/beni/${v}.beni`, join(out, `beni-${v.toLowerCase()}`));
  for (const [app, { entries, cmd }] of Object.entries(npmApps)) {
    const dir = join(apps, app);
    if (!existsSync(join(dir, "node_modules"))) run("npm", ["ci", "--no-audit", "--no-fund"], dir);
    for (const e of entries) {
      rmSync(join(out, `${app}-${e}`), { recursive: true, force: true });
      const [c, args, env] = cmd(e);
      run(c, args, dir, env);
    }
  }
}

// ---- Measuring ----------------------------------------------------------------

const require = createRequire(join(apps, "solid1/package.json"));
const { minify } = require("terser");
const { rollup } = require("rollup");

const br = (s) => {
  const b = Buffer.from(s);
  return brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: b.length } }).length;
};
const gz = (s) => gzipSync(Buffer.from(s), { level: 9 }).length;
const raw = (s) => Buffer.byteLength(s);
const walk = (dir) =>
  readdirSync(dir)
    .sort()
    .flatMap((f) => {
      const p = join(dir, f);
      return statSync(p).isDirectory() ? walk(p) : /\.(m?js)$/.test(f) ? [p] : [];
    });
const version = (app, pkg) => JSON.parse(readFileSync(join(apps, app, "node_modules", pkg, "package.json"), "utf8")).version;
// The same minifier for every subject, so the minifiers' differences are
// seen apart from the frameworks'.
const terse = async (text) => (await minify(text, { module: true, compress: { passes: 2 }, mangle: { toplevel: true } })).code;

const beniVersion = spawnSync(beni, ["version"], { encoding: "utf8" }).stdout.trim();
const subjects = [
  ["beni", `beni (${beniVersion})`, "beni", "no edit"],
  ["beni-full", `beni (${beniVersion})`, "beni-full", "whole spec"],
  ["solid1-full", `Solid ${version("solid1", "solid-js")}`, "solid1-full", "official; whole spec but the filter at start"],
  ["solid1-parity", `Solid ${version("solid1", "solid-js")}`, "solid1-parity", "beni's features"],
  ["solid2-full", `Solid ${version("solid2", "solid-js")}`, "solid2-full", "port of the official; whole spec"],
  ["solid2-parity", `Solid ${version("solid2", "solid-js")}`, "solid2-parity", "beni's features"],
  ["svelte5-asis", `Svelte ${version("svelte5", "svelte")}`, "svelte5-asis", "official; no persistence, no filter at start"],
  ["svelte5-full", `Svelte ${version("svelte5", "svelte")}`, "svelte5-full", "whole spec"],
  ["svelte5-parity", `Svelte ${version("svelte5", "svelte")}`, "svelte5-parity", "beni's features"],
  ["svelte4-asis", `Svelte ${version("svelte4", "svelte")}`, "svelte4-asis", "official; no persistence, no filter at start"],
  ["svelte4-full", `Svelte ${version("svelte4", "svelte")}`, "svelte4-full", "whole spec"],
  ["svelte4-parity", `Svelte ${version("svelte4", "svelte")}`, "svelte4-parity", "beni's features"],
];

const rows = [];
for (const [id, framework, dir, features] of subjects) {
  const texts = walk(join(out, dir)).map((f) => readFileSync(f, "utf8"));
  const all = texts.join("\n");
  const tersed = (await Promise.all(texts.map(terse))).join("\n");
  rows.push({ id, framework, features, files: texts.length, raw: raw(all), gzip: gz(all), brotli: br(all), terser_brotli: br(tersed) });
}

const row = (...cells) => console.log(`| ${cells.join(" | ")} |`);
if (json) for (const r of rows) console.log(JSON.stringify(r));
else {
  console.log("## TodoMVC, every JavaScript byte the page loads\n");
  row("subject", "framework", "features", "files", "raw", "gzip -9", "**brotli 11**", "each file through terser, brotli");
  row("---", "---", "---", "--:", "--:", "--:", "--:", "--:");
  for (const r of rows) row(r.id, r.framework, r.features, r.files, r.raw, r.gzip, `**${r.brotli}**`, r.terser_brotli);
}

// ---- beni by module ------------------------------------------------------------

// Every emitted module and sibling, in groups the report names.
const groups = [
  ["the app (TodoMVC.mjs)", /^TodoMVC\.mjs$/],
  ["DOM runtime (Rt)", /_browser\/Rt\.mjs$/],
  ["fiber kernel (core Task)", /_core\/Task\.mjs$/],
  ["TEA (Tea, Cmd, Sub)", /(_platform\/Tea|_browser\/Cmd|_browser\/Sub)\.mjs$/],
  ["program host (Browser, Hosted, Listen)", /_browser\/(Browser|Hosted|Hosted\.foreign|Listen)\.mjs$/],
  ["List", /_core\/List\.mjs$/],
  ["Dict", /_core\/Dict\.mjs$/],
  ["String", /_core\/String\.mjs$/],
  ["Storage", /_browser\/Storage\.mjs$/],
  ["Url and Browser.Navigation", /(_core\/Url|Browser\/Navigation)\.mjs$/],
  ["Html (event readers)", /_html\/Html(\.foreign)?\.mjs$/],
  ["Basics, Maybe", /_core\/(Basics|Maybe)\.mjs$/],
  ["entry file", /^_main\.mjs$/],
];
const groupOf = (src) => groups.find(([, re]) => re.test(src))?.[0] ?? `other: ${src}`;

const dev = join(out, "beni-dev");
const bundle = await rollup({ input: join(dev, "_main.mjs"), logLevel: "silent" });
const { output } = await bundle.generate({ format: "es", sourcemap: true, sourcemapExcludeSources: true });
const hoisted = output[0];
const min = await minify(hoisted.code, {
  module: true,
  compress: { passes: 2 },
  mangle: { toplevel: true },
  sourceMap: { content: hoisted.map, asObject: true },
});
const map = new SourceMap(min.map);
const chars = new Map();
const lines = min.code.split("\n");
const owner = [];
lines.forEach((line, l) => {
  let last = "(unmapped)";
  for (let c = 0; c < line.length; c++) {
    const e = map.findEntry(l, c);
    // An entry covers the bytes up to the next one; a byte with none is the
    // previous byte's.
    if (e && e.originalSource !== undefined) last = groupOf(e.originalSource.replace(/\\/g, "/").replace(/.*beni-dev\//, ""));
    owner.push(last);
  }
  owner.push(last); // the newline
});
const proxy = min.code;
for (let i = 0; i < proxy.length; i++) chars.set(owner[i], (chars.get(owner[i]) ?? "") + proxy[i]);
const release = walk(join(out, "beni")).map((f) => readFileSync(f, "utf8")).join("\n");
const proxyBr = br(proxy);
const byModule = [...chars].map(([g, s]) => {
  const without = [...proxy].filter((_, i) => owner[i] !== g).join("");
  return { group: g, raw: raw(s), brotli_alone: br(s), leave_one_out: proxyBr - br(without) };
});
byModule.sort((a, b) => b.raw - a.raw);

// ---- beni by feature -----------------------------------------------------------

const base = rows.find((r) => r.id === "beni");
const features = beniVariants
  .filter((v) => v !== "Full")
  .map((v) => {
    const t = walk(join(out, `beni-${v.toLowerCase()}`)).map((f) => readFileSync(f, "utf8")).join("\n");
    return { variant: v, raw: raw(t), brotli: br(t), delta_brotli: br(t) - base.brotli };
  });

// ---- Candidate reductions, hand-applied --------------------------------------

// Each candidate is a text rewrite of the release file that prices a fix
// before it is built (backend.md §9's discipline, bench/ui/anatomy.mjs's
// method). Every text, the release file included, then goes through one
// pass that only drops top-level bindings nothing mentions any more
// (terser with every other transformation off), so a rewrite that strands a
// helper is charged without it. The rewrites match the compiler's output at
// the commit research 51 was measured on; one whose text is no longer there
// prints as not applicable rather than a number.
const shake = async (t) =>
  (await minify(t, { module: true, compress: { defaults: false, unused: true, toplevel: true }, mangle: false })).code;
const replaceAll = (t, pairs) => {
  for (const [a, b] of pairs) {
    if (!t.includes(a)) return null;
    t = t.split(a).join(b);
  }
  return t;
};
const urlPart = release.slice(release.indexOf("const Mc={$:1,a:null},Nc="), release.indexOf("const Qc="));
const noRouting = walk(join(out, "beni-norouting")).map((f) => readFileSync(f, "utf8")).join("\n");
const candidates = [
  [
    "constant `href`s in the template, not holes through `safeUrl`",
    (t) =>
      replaceAll(t, [
        ["<li><a>All</a></li><li><a>Active</a></li><li><a>Completed</a></li>", "<li><a href=#/>All</a></li><li><a href=#/active>Active</a></li><li><a href=#/completed>Completed</a></li>"],
        ['o.setAttribute("href",nb(a[12]));', ""],
        ['q.setAttribute("href",nb(a[14]));', ""],
        ['s.setAttribute("href",nb(a[16]));', ""],
        ['"#/",n,"#/active",o,"#/completed",p', "n,o,p"],
      ]),
  ],
  [
    "reads of `For` kind fields no kind writes (`g`, `z`, `b`, `w`) folded",
    (t) =>
      replaceAll(t, [
        [
          "let e=d.g,f=a.b!==null,g=f&&(e===undefined?cb(a.y):db(a.y,e)),h=e!==undefined&&f&&a.z!==d.z,i=h?a.z:eb,j=h?d.z:eb;if(e!==undefined)a.z=d.z;if(b===a.b&&g){if(i!==j){a.y=null;fb(a,d,i);fb(a,d,j)}}else{",
          "let g=a.b!==null&&a.y===null,i=eb,j=eb;if(b!==a.b||!g){",
        ],
        ["if(a.b===undefined){e=a.m(b,c,d);if(a.w===true)a.p(e,b,c)}else e=Oa(a.b(b,c),d);", "e=a.m(b,c,d);"],
        ["if(a.b===undefined){a.p(b,c,d);return b}let f=Pa(b,a.b(c,d),e);if(f!==b){f.k=b.k;f.n=null;f.kv=0;f.kc=b.kc;f.kt=null}return f", "a.p(b,c,d);return b"],
      ]),
  ],
  [
    "a `case` on `Cmd` items collapsed to the one constructor built",
    (t) =>
      replaceAll(t, [
        [
          "switch(b.$){case 0:{return undefined}case 1:{let d=b.a,e=tc(a);({a:ya(()=>wc(d,a=>uc(e,a)))});return c}case 2:{return undefined}case 3:{return undefined}case 4:{return undefined}case 5:{return undefined}default:{return undefined}}",
          "let d=b.a,e=tc(a);ya(()=>wc(d,a=>uc(e,a)));return c",
        ],
      ]),
  ],
  ["`String.join` as the array's `join`", (t) => replaceAll(t, [['lc=a=>{if(a.length===0)return"";let b=Ob(a);return Wb(Sb(a),b,(a,b)=>b+"\\n"+a)}', 'lc=a=>_a(a).join("\\n")']])],
  ["`String.startsWith` as the string's `startsWith`", (t) => replaceAll(t, [['oc=a=>mc(a,fc("1"))==="1"', 'oc=a=>a.startsWith("1")']])],
  [
    "the `Url` fields the program never reads not built",
    (t) =>
      replaceAll(t, [
        [
          'Oc=(a,b)=>{let c=b.href,d=b.hash,e=b.search,f=b.port,g=d===""&&c.endsWith("#"),h=g?1:d.length,i=c.slice(0,c.length-h),j=b.hostname,k=f===""?Mc:jc(f),l=b.pathname,m=e!==""?{$:0,a:e.slice(1)}:i.endsWith("?")?{$:0,a:""}:Mc;return{r:d!==""?{$:0,a:d.slice(1)}:g?{$:0,a:""}:Mc,t:j,v:l,A:k,protocol:a,B:m}}',
          'Oc=(a,b)=>{let c=b.href,d=b.hash,g=d===""&&c.endsWith("#");return{r:d!==""?{$:0,a:d.slice(1)}:g?{$:0,a:""}:Mc}}',
        ],
      ]),
  ],
  [
    "the browser's macrotask without Node's `setImmediate` test",
    (t) =>
      replaceAll(t, [
        [
          'const q=a=>{let b=globalThis.setImmediate;if(typeof b==="function")b(a);else{if(o===null){let c=new globalThis.MessageChannel();c.port1.onmessage=()=>{let b=p;p=null;return b()};o=c.port2}p=a;o.postMessage(null)}};',
          "const q=a=>{if(o===null){let c=new MessageChannel();c.port1.onmessage=()=>{let b=p;p=null;return b()};o=c.port2}p=a;o.postMessage(null)};",
        ],
      ]),
  ],
  [
    "subscription keys compared as strings, not by the generic structural compare",
    (t) => {
      const i = t.indexOf("const Md=");
      const j = t.indexOf("const rc=");
      return i < 0 || j < i ? null : t.slice(0, i) + "const Od=(r,s)=>r<s?-1:r>s?1:0;" + t.slice(j);
    },
  ],
  [
    "the page kind's mount writing its holes through its own patch (time it)",
    (t) => {
      const i = t.indexOf("e.value=a[0];e.$$input=a[1];");
      const end = "a16:a[18],a17:a[19]}},p:";
      const j = t.indexOf(end);
      if (i < 0 || j < i) return null;
      return (
        t.slice(0, i) +
        'let v=$a(j,"");e.$$inputX=Wc;e.$$keydownX=ob;g.$$changeX=Xc;if(b!==null){e.$$cx=b;g.$$cx=b;t.$$cx=b}o.setAttribute("href",nb(a[12]));q.setAttribute("href",nb(a[14]));s.setAttribute("href",nb(a[16]));let r={s:c,q:null,e:c,w4:e,w5:f,w6:g,w10:i,w13:l,w16:o,w19:q,w22:s,w24:t,c6:u,x9:v};Ed.p(r,a);return r},p:' +
        t.slice(j + end.length)
      );
    },
  ],
  ["the keyed `For`'s trimmed first pass gone (time it)", (t) => replaceAll(t, [["if(!(a.d&&jb(a,b,c,d,g,i,j))){", "{"]])],
  [
    "routing as a plain `popstate` listener: no subscription fiber, table or relay (an estimate)",
    () =>
      noRouting +
      urlPart +
      'const Uc=()=>Pc(location.href),Vc=a=>{let b=()=>{let c=Uc();if(c.$===0)a(c.a)};addEventListener("popstate",b);addEventListener("beni:navigate",b)};Vc(a=>a);',
  ],
  [
    "information, not a candidate: `++` on lists without the 32-way trie (the decided representation)",
    (t) => {
      const i = t.indexOf("Mb=(a,b)=>{");
      const j = t.indexOf("},Nb=", i);
      return i < 0 || j < i ? null : t.slice(0, i) + "Mb=(a,b)=>b.length===0?a:a.length===0?b:wb(a).concat(wb(b))" + t.slice(j + 1);
    },
  ],
];
const shakenRelease = await shake(release);
const shakenBr = br(shakenRelease);
const priced = [];
let together = release;
for (const [name, rewrite] of candidates) {
  const t = rewrite(release);
  if (t === null) {
    priced.push({ candidate: name, applicable: false });
    continue;
  }
  const s = await shake(t);
  priced.push({ candidate: name, applicable: true, raw: raw(s) - raw(shakenRelease), brotli: br(s) - shakenBr });
  if (!name.includes("time it") && !name.includes("estimate") && !name.startsWith("information")) together = rewrite(together) ?? together;
}
const togetherShaken = await shake(together);
priced.push({ candidate: "every zero-cost rewrite above together", applicable: true, raw: raw(togetherShaken) - raw(shakenRelease), brotli: br(togetherShaken) - shakenBr });

if (json) {
  console.log(JSON.stringify({ release_raw: raw(release), release_brotli: br(release), proxy_raw: raw(proxy), proxy_brotli: proxyBr }));
  for (const m of byModule) console.log(JSON.stringify(m));
  for (const f of features) console.log(JSON.stringify(f));
  for (const c of priced) console.log(JSON.stringify(c));
} else {
  console.log(`\n## beni's TodoMVC by module\n`);
  console.log(`The release file: ${raw(release)} raw, ${br(release)} brotli. The proxy (development build,`);
  console.log(`Rollup, terser): ${raw(proxy)} raw, ${proxyBr} brotli.\n`);
  row("group", "proxy raw", "share", "brotli alone", "leave-one-out");
  row("---", "--:", "--:", "--:", "--:");
  for (const m of byModule) row(m.group, m.raw, `${((100 * m.raw) / raw(proxy)).toFixed(1)} %`, m.brotli_alone, m.leave_one_out);
  console.log(`\n## beni's TodoMVC by feature (release builds of apps/beni/)\n`);
  row("variant", "raw", "brotli", "Δ brotli against the TodoMVC");
  row("---", "--:", "--:", "--:");
  row("TodoMVC (tests/corpus/browser/tea)", base.raw, base.brotli, 0);
  for (const f of features) row(f.variant, f.raw, f.brotli, f.delta_brotli);
  console.log(`\n## Candidate reductions, hand-applied to the release file\n`);
  console.log(`The release file with unmentioned bindings dropped: ${raw(shakenRelease)} raw, ${shakenBr} brotli.\n`);
  row("candidate", "Δ raw", "Δ brotli");
  row("---", "--:", "--:");
  for (const c of priced) row(c.candidate, c.applicable ? c.raw : "n/a", c.applicable ? c.brotli : "n/a");
}
