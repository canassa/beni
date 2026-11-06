// Build the compiled beni benchmark, in release and development form.
// The adapter reads both outputs to match the exported short names.
import { spawnSync } from "node:child_process";
import { mkdirSync, copyFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
let beni = resolve(here, "../../../zig-out/bin/beni");
for (const arg of process.argv.slice(2)) {
  if (arg.startsWith("--beni=")) beni = resolve(arg.slice("--beni=".length));
}
const root = process.env.BENI_SCHEMA_OUT ?? here;
for (const [name, flags] of [["compiled", []]]) {
  const project = join(root, `project-${name}`);
  mkdirSync(project, { recursive: true });
  copyFileSync(join(here, "Bench.beni"), join(project, "Bench.beni"));
  // The release build, and a development one whose export list names what
  // the release one's short names are, position for position.
  for (const [dir, release] of [[`out-${name}`, ["--release"]], [`names-${name}`, ["--no-source-maps"]]]) {
    const r = spawnSync(beni, ["build", "--platform=node", "--library", "--no-cache", ...release, ...flags, `--out=${join(root, dir)}`, "Bench.beni"], { cwd: project, encoding: "utf8" });
    if (r.status !== 0) {
      process.stderr.write(r.stdout + r.stderr);
      process.exit(1);
    }
  }
}
