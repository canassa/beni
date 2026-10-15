// Builds the example programs into a static site for GitHub Pages.
// `.github/workflows/pages.yml` runs it on every push to master and
// deploys its output.
//
// usage: node examples/build-pages.mjs <beni> <out> <base> [--playground=<dir>]
//   <beni>  the compiler to run
//   <out>   the directory to write; it is emptied first
//   <base>  the URL path <out> is served under, from "/" to a final "/";
//           on GitHub Pages, canassa/beni's is /beni/
//   --playground=<dir>
//           a static site with an index.html at its top, served as
//           <base>playground/ (issue #128): its URLs must be relative. With
//           no playground, the index page marks it as coming.
//
// The site: <out>/index.html links to each program, and each program is at
// <out>/<name>/. <out>/404.html is what GitHub Pages answers for a path that
// names no file.
//
// The page shell loads the entry by an absolute path, the project's
// "build"."base" followed by the entry file (backend.md §2, *The page
// shell*). The base has no flag, so each program is built from a copy whose
// beni.json says <base><name>/. The checked-in examples do not change.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Each program is a --release build.
const programs = [
  { name: "sternhalma" },
  { name: "bike-wars" },
  // Conduit routes by path and calls the RealWorld API. Its `Deploy` module
  // says where both are: by default the root of the page's own origin, as
  // the corpus serves it. The copy here gets a module with this site's path
  // and a public demo API, whose CORS headers allow the site's origin.
  { name: "conduit", routesByPath: true, deploy: { apiOrigin: "https://api.realworld.show" } },
];

const args = process.argv.slice(2);
const playgroundArg = args.find((arg) => arg.startsWith("--playground="));
const [beniArg, outArg, base, ...rest] = args.filter((arg) => arg !== playgroundArg);
if (!beniArg || !outArg || !base || rest.length > 0 || !/^\/([A-Za-z0-9._~-]+\/)*$/.test(base)) {
  console.error("usage: node examples/build-pages.mjs <beni> <out> <base, from / to a final /> [--playground=<dir>]");
  process.exit(2);
}

const here = dirname(fileURLToPath(import.meta.url));
const beni = resolve(beniArg);
const out = resolve(outArg);
const git = (...gitArgs) => execFileSync("git", ["-C", here, ...gitArgs], { encoding: "utf8" }).trim();

// A string the generated `Deploy` module holds: no quote, backslash or `$`,
// which a beni string literal would read as something else.
const beniString = (text) => {
  if (!/^[A-Za-z0-9._~:/-]*$/.test(text)) throw new Error(`not a plain URL text: ${text}`);
  return `"${text}"`;
};

const deployModule = ({ basePath, apiOrigin }) => `--! Written by examples/build-pages.mjs for GitHub Pages.

pub basePath : String
basePath = ${beniString(basePath)}


pub apiOrigin : String
apiOrigin = ${beniString(apiOrigin)}
`;

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const work = mkdtempSync(join(tmpdir(), "beni-pages-"));
try {
  for (const { name, deploy, routesByPath } of programs) {
    const source = join(here, name);
    const copy = join(work, name);
    cpSync(source, copy, {
      recursive: true,
      filter: (path) => !["out", ".beni-cache"].includes(basename(path)),
    });
    const manifestPath = join(copy, "beni.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    // 404.html stands in for the page of a program that routes by path, so
    // that page must be the default shell: the entry script and an empty
    // body. A shell of the program's own would hold more.
    if (routesByPath && manifest.html !== undefined) {
      throw new Error(`${name}: 404.html stands in for its page, so it cannot declare an "html" shell`);
    }
    manifest.build.base = `${base}${name}/`;
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    if (deploy) {
      writeFileSync(join(copy, "src", "Deploy.beni"), deployModule({ basePath: `${base}${name}`, ...deploy }));
    }

    const dest = join(out, name);
    execFileSync(beni, ["build", "--no-cache", "--release", `--out=${dest}`], { cwd: copy, stdio: "inherit" });

    const entry = `${base}${name}/_main.mjs`;
    if (!readFileSync(join(dest, "index.html"), "utf8").includes(`"${entry}"`)) {
      throw new Error(`${name}: index.html does not load ${entry}`);
    }
    if (deploy) {
      const emitted = readdirSync(dest, { recursive: true })
        .filter((path) => path.endsWith(".mjs"))
        .map((path) => readFileSync(join(dest, path), "utf8"))
        .join("\n");
      for (const value of [`${base}${name}`, deploy.apiOrigin]) {
        if (!emitted.includes(value)) throw new Error(`${name}: the build does not hold ${value}`);
      }
    }

    // A port's notice ships with its build.
    if (existsSync(join(source, "LICENSE"))) {
      cpSync(join(source, "LICENSE"), join(dest, "LICENSE.txt"));
    }
    if (existsSync(join(source, "licenses"))) {
      cpSync(join(source, "licenses"), join(dest, "licenses"), { recursive: true });
    }
    console.log(`built ${name} -> ${dest}`);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}

let playground = 'Playground <span class="tag">coming</span>';
if (playgroundArg) {
  const dir = resolve(playgroundArg.slice("--playground=".length));
  if (!existsSync(join(dir, "index.html"))) throw new Error(`${dir} has no index.html`);
  cpSync(dir, join(out, "playground"), { recursive: true });
  playground = '<a href="./playground/">Playground</a>';
  console.log(`copied the playground ${dir} -> ${join(out, "playground")}`);
}

const fill = (file, values) => {
  let page = readFileSync(join(here, file), "utf8");
  for (const [key, value] of Object.entries(values)) page = page.replaceAll(`{{${key}}}`, value);
  const left = page.match(/\{\{[^}]*\}\}/);
  if (left) throw new Error(`${file}: nothing fills ${left[0]}`);
  writeFileSync(join(out, file), page);
  console.log(`wrote ${join(out, file)}`);
};

const commit = git("rev-parse", "HEAD");
fill("index.html", {
  commit,
  short: commit.slice(0, 9),
  date: git("log", "-1", "--format=%cs"),
  playground,
});
fill("404.html", {
  base,
  apps: JSON.stringify(programs.filter((p) => p.routesByPath).map((p) => `${base}${p.name}/`)),
});
