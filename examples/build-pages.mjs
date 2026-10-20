// Builds the example programs into a static site for GitHub Pages.
// `.github/workflows/pages.yml` runs it on every push to master and
// deploys its output.
//
// usage: node examples/build-pages.mjs <beni> <out> <base> [--playground=<dir>]
//   <beni>  the compiler to run
//   <out>   the directory to write; it is emptied first, so it must be
//           missing, empty, or a site this script wrote (it holds the
//           marker file .beni-pages-site), and must not hold the repository
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
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

// Each program is a --release build.
const programs = [
  { name: "sternhalma" },
  { name: "bike-wars" },
  { name: "steer" },
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

// What a site build leaves in <out>, so that a later run knows the
// directory is its own. upload-pages-artifact leaves out files whose names
// start with ".", so the marker is not published.
const marker = ".beni-pages-site";
const refuse = (why) => {
  console.error(`build-pages: refusing ${out}: ${why}`);
  process.exit(2);
};
if (existsSync(out)) {
  const real = realpathSync(out);
  const toRepo = relative(real, realpathSync(git("rev-parse", "--show-toplevel")));
  if (toRepo === "" || !(toRepo === ".." || toRepo.startsWith(`..${sep}`) || isAbsolute(toRepo))) {
    refuse("it holds the repository");
  }
  if (!statSync(real).isDirectory()) refuse("it is not a directory");
  if (readdirSync(real).length > 0 && !existsSync(join(real, marker))) {
    refuse(`it is not empty and has no ${marker}, so no site build wrote it`);
  }
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
writeFileSync(join(out, marker), "Written by examples/build-pages.mjs, which empties this directory on its next run.\n");

const routed = [];
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
    manifest.build.base = `${base}${name}/`;
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    if (deploy) {
      writeFileSync(join(copy, "src", "Deploy.beni"), deployModule({ basePath: `${base}${name}`, ...deploy }));
    }

    const dest = join(out, name);
    execFileSync(beni, ["build", "--no-cache", "--release", `--out=${dest}`], { cwd: copy, stdio: "inherit" });

    const entry = `${base}${name}/_main.mjs`;
    const shell = readFileSync(join(dest, "index.html"), "utf8");
    if (!shell.includes(`"${entry}"`)) {
      throw new Error(`${name}: index.html does not load ${entry}`);
    }
    // 404.html stands in for the page of a program that routes by path: it
    // holds the page shell the build wrote and puts it in place of itself.
    if (routesByPath) routed.push({ base: `${base}${name}/`, shell });
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
  const template = readFileSync(join(here, file), "utf8");
  // The template is checked and filled in one pass, so a value is never
  // read again: a program's shell in it may hold a "{{" or a "$" of its own.
  const placeholder = /\{\{([^}]*)\}\}/g;
  for (const [hole, key] of template.matchAll(placeholder)) {
    if (!Object.hasOwn(values, key)) throw new Error(`${file}: nothing fills ${hole}`);
  }
  const page = template.replace(placeholder, (_, key) => values[key]);
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
// The shells go into a <script>, where a "</script>" or "<!--" in one
// would end or change the script: JSON's \u003c keeps every "<" out of it.
fill("404.html", {
  base,
  apps: JSON.stringify(routed).replaceAll("<", "\\u003c"),
});
