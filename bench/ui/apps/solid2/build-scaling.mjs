// The scaling sweeps' Solid 2 programs (bench/ui/scaling.mjs), each built
// as vite.config.mjs builds the table benchmark's page: one self-contained
// ES module minified with terser. Argument: a JSON file of
// `[input, outDir, name]` triples; writes `<outDir>/<name>.js`.
import { readFileSync } from "node:fs";
import solid from "@solidjs/vite-plugin";
import { build } from "vite";

const entries = JSON.parse(readFileSync(process.argv[2], "utf8"));
for (const [input, outDir, name] of entries) {
  await build({
    configFile: false,
    root: import.meta.dirname,
    logLevel: "warn",
    plugins: [solid()],
    build: {
      outDir,
      emptyOutDir: false,
      minify: "terser",
      modulePreload: false,
      rollupOptions: {
        input: { [name]: input },
        output: { entryFileNames: "[name].js", format: "es", codeSplitting: false },
      },
    },
  });
}
