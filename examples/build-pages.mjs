// Builds the example programs into a static site for GitHub Pages.
// `.github/workflows/pages.yml` runs it on every push to master and
// publishes its output as the gh-pages branch's /examples/.
//
// usage: node examples/build-pages.mjs <beni> <out> <base>
//   <beni>  the compiler to run
//   <out>   the directory to write; it is emptied first
//   <base>  the URL path <out> is served under, from "/" to a final "/";
//           on GitHub Pages, canassa/beni's is /beni/examples/
//
// The page shell loads the entry by an absolute path, the project's
// "build"."base" followed by the entry file (backend.md §2, *The page
// shell*). The base has no flag, so each program is built from a copy whose
// beni.json says <base><name>/. The checked-in examples do not change.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const programs = [
  { name: "sternhalma", flags: ["--release"] },
  // A development build: the port keeps the original's `Debug.log`, and
  // `--release` refuses `Debug` (backend.md §9).
  { name: "bike-wars", flags: [] },
  // Conduit is not here: it calls its API at /api on its own origin, and
  // GitHub Pages serves static files only.
];

const [beniArg, outArg, base] = process.argv.slice(2);
if (!beniArg || !outArg || !base || !base.startsWith("/") || !base.endsWith("/")) {
  console.error("usage: node examples/build-pages.mjs <beni> <out> <base, from / to a final />");
  process.exit(2);
}

const here = dirname(fileURLToPath(import.meta.url));
const beni = resolve(beniArg);
const out = resolve(outArg);
const git = (...args) => execFileSync("git", ["-C", here, ...args], { encoding: "utf8" }).trim();

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const work = mkdtempSync(join(tmpdir(), "beni-pages-"));
try {
  for (const { name, flags } of programs) {
    const source = join(here, name);
    const copy = join(work, name);
    cpSync(source, copy, {
      recursive: true,
      filter: (path) => !["out", ".beni-cache"].includes(basename(path)),
    });
    const manifestPath = join(copy, "beni.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.build.base = `${base}${name}/`;
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

    const dest = join(out, name);
    execFileSync(beni, ["build", "--no-cache", `--out=${dest}`, ...flags], { cwd: copy, stdio: "inherit" });

    const entry = `${base}${name}/_main.mjs`;
    if (!readFileSync(join(dest, "index.html"), "utf8").includes(`"${entry}"`)) {
      throw new Error(`${name}: index.html does not load ${entry}`);
    }

    // Each port is BSD-3-Clause, so its notice ships with its build.
    cpSync(join(source, "LICENSE"), join(dest, "LICENSE.txt"));
    if (existsSync(join(source, "licenses"))) {
      cpSync(join(source, "licenses"), join(dest, "licenses"), { recursive: true });
    }
    console.log(`built ${name} -> ${dest}`);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}

const commit = git("rev-parse", "HEAD");
const page = readFileSync(join(here, "index.html"), "utf8")
  .replaceAll("{{commit}}", commit)
  .replaceAll("{{short}}", commit.slice(0, 9))
  .replaceAll("{{date}}", git("log", "-1", "--format=%cs"));
writeFileSync(join(out, "index.html"), page);
console.log(`wrote ${join(out, "index.html")}`);
