import { brotliCompressSync, constants } from "node:zlib";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { build } from "esbuild";
import { checkResult } from "./correctness.mjs";
import { entryPath, serializeError } from "./measure-common.mjs";

export async function measureBundles({ rootUrl, rows, adapters, cases, progress = () => {} }) {
  const directory = await mkdtemp(join(tmpdir(), "beni-schema-bundles-"));
  const reports = [];
  try {
    for (const row of rows) {
      const adapter = adapters.find((item) => item.meta.id === row);
      for (const direction of ["decode", "encode"]) {
        if (!adapter || !(adapter.meta.supportedDirections ?? adapter.meta.directions ?? ["decode", "encode"]).includes(direction)) continue;
        const entry = new URL(entryPath(rootUrl, row, direction));
        try {
          await access(entry);
          progress(`bundle ${row}/${direction}`);
          const outfile = join(directory, `${row}-${direction}.mjs`);
          const result = await build({
            entryPoints: [entry.pathname],
            outfile,
            bundle: true,
            format: "esm",
            platform: "browser",
            target: "es2022",
            minify: true,
            treeShaking: true,
            metafile: true,
            logLevel: "silent",
          });
          const bytes = await readFile(outfile);
          const inputs = Object.keys(result.metafile.inputs).sort();
          const flatOnlyOffenders = inputs.filter((input) =>
            /(?:^|\/)fixtures\.mjs$|(?:^|\/)payloads\/|(?:^|\/)typia\/generated\/input\.js$/.test(input)
            || /(?:^|\/)adapters\/(?!_issues\.mjs$)/.test(input));
          const outputMeta = Object.values(result.metafile.outputs)[0];
          const inputContributions = Object.fromEntries(Object.entries(outputMeta.inputs).map(([input, detail]) => [input, detail.bytesInOutput]));
          let execution;
          try {
            const bundled = await import(`${pathToFileURL(outfile).href}?audit=${Date.now()}`);
            const run = bundled.run ?? bundled.default;
            if (typeof run !== "function") throw new Error("bundle does not export run/default function");
            const bundleCases = cases.filter((item) => item.workload === "flat" && item.direction === direction && (row !== "json-floor" || item.path === "valid"));
            for (const testCase of bundleCases) {
              const input = row === "json-floor" ? testCase.jsonFloorInput : testCase.input;
              const before = structuredClone(input);
              const actual = run(input);
              if (!isDeepStrictEqual(input, before)) throw new Error(`bundle mutated ${testCase.path} input`);
              if (row === "json-floor") {
                if (!actual?.ok) throw new Error("JSON floor bundle rejected valid input");
                if (direction === "encode" && !isDeepStrictEqual(JSON.parse(actual.value), input)) throw new Error("JSON floor bundle changed wire payload");
              } else {
                const reason = checkResult(testCase, actual);
                if (reason) throw new Error(`bundle ${testCase.path}: ${reason}`);
              }
            }
            execution = { passed: true, cases: bundleCases.map((item) => item.path) };
          } catch (error) {
            execution = { passed: false, error: serializeError(error) };
          }
          reports.push({
            row,
            direction,
            raw_bytes: bytes.length,
            brotli_bytes: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length,
            inputs,
            input_bytes_in_output: inputContributions,
            flat_only_audit: { passed: flatOnlyOffenders.length === 0, offenders: flatOnlyOffenders },
            execution,
          });
        } catch (error) {
          reports.push({ row, direction, error: serializeError(error) });
        }
      }
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
  return reports;
}
