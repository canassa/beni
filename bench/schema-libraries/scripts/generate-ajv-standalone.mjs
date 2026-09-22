import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";
import standaloneCode from "ajv/dist/standalone/index.js";
import { schemaFor } from "../spec.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const output = resolve(here, "../generated/ajv-standalone.mjs");
const ajv = new Ajv({
  allErrors: false,
  code: { esm: true, source: true },
  coerceTypes: false,
  strict: true,
  useDefaults: false,
});
const exports = {};

for (const workload of ["flat", "list", "union", "tree", "typeahead"]) {
  for (const direction of ["decode", "encode"]) {
    const name = `${workload}_${direction}`;
    const id = `beni:${name}`;
    ajv.addSchema({ ...schemaFor(workload, direction), $id: id }, id);
    exports[name] = id;
  }
}

await mkdir(dirname(output), { recursive: true });
await writeFile(output, standaloneCode(ajv, exports));

for (const direction of ["decode", "encode"]) {
  const single = new Ajv({
    allErrors: false,
    code: { esm: true, source: true },
    coerceTypes: false,
    strict: true,
    useDefaults: false,
  });
  const validate = single.compile(schemaFor("flat", direction));
  const path = resolve(here, `../generated/ajv-standalone/flat-${direction}.mjs`);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, standaloneCode(single, validate));
}
