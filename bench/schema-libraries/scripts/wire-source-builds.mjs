import { cp, mkdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const benchmarkDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoDir = path.resolve(benchmarkDir, "../..");
const nodeModules = path.join(benchmarkDir, "node_modules");
const stagingDir = path.join(benchmarkDir, ".source-build/packages");

async function json(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

async function stageBuiltPackage(name, sourceDir, builtDir) {
  const installedManifest = await json(path.join(nodeModules, name, "package.json"));
  const sourceManifest = await json(path.join(sourceDir, "package.json"));
  if (installedManifest.version !== sourceManifest.version) {
    throw new Error(`${name}: registry metadata ${installedManifest.version} != source ${sourceManifest.version}`);
  }
  const destination = path.join(stagingDir, name);
  await rm(destination, { recursive: true, force: true });
  await mkdir(destination, { recursive: true });
  await cp(builtDir, path.join(destination, path.basename(builtDir)), { recursive: true });
  await writeFile(path.join(destination, "package.json"), `${JSON.stringify(installedManifest, null, 2)}\n`);
  return destination;
}

await mkdir(stagingDir, { recursive: true });
const typiaSource = path.join(repoDir, "references/typia/packages/typia");
const effectSource = path.join(repoDir, "references/effect/packages/effect");
const typiaStaged = await stageBuiltPackage("typia", typiaSource, path.join(typiaSource, "lib"));
// The ttsc descriptor resolves the native Go transformer relative to the
// package root; it is source input rather than part of lib/.
await cp(path.join(typiaSource, "native"), path.join(typiaStaged, "native"), { recursive: true });
const effectStaged = await stageBuiltPackage("effect", effectSource, path.join(effectSource, "dist"));

const targets = new Map([
  ["ajv", path.join(repoDir, "references/ajv")],
  ["typia", typiaStaged],
  ["typebox", path.join(repoDir, "references/typebox/target/build")],
  ["arktype", path.join(repoDir, "references/arktype/ark/type")],
  ["fast-json-stringify", path.join(repoDir, "references/fast-json-stringify")],
  ["zod", path.join(repoDir, "references/zod/packages/zod")],
  ["valibot", path.join(repoDir, "references/valibot/library")],
  ["effect", effectStaged]
]);

for (const [name, target] of targets) {
  const installed = path.join(nodeModules, name);
  await rm(installed, { recursive: true, force: true });
  await symlink(path.relative(nodeModules, target), installed, "dir");
  const resolved = await realpath(installed);
  if (resolved !== target) throw new Error(`${name}: expected ${target}, resolved ${resolved}`);
  process.stderr.write(`${name} -> ${path.relative(repoDir, target)}\n`);
}
