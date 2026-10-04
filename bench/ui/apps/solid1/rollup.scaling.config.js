// The scaling sweeps' Solid 1 programs (bench/ui/scaling.mjs), each built
// exactly as rollup.config.js builds the table benchmark's: one IIFE per
// program. `SCALING_ENTRIES` names a JSON file of `[input, output]` pairs.
import { readFileSync } from "node:fs";
import resolve from "@rollup/plugin-node-resolve";
import { babel } from "@rollup/plugin-babel";
import terser from "@rollup/plugin-terser";

const entries = JSON.parse(readFileSync(process.env.SCALING_ENTRIES, "utf8"));

export default entries.map(([input, file]) => ({
  input,
  output: { file, format: "iife" },
  plugins: [
    babel({
      babelHelpers: "bundled",
      exclude: "node_modules/**",
      presets: [["solid", { omitNestedClosingTags: true }]],
    }),
    resolve({ extensions: [".js", ".jsx"] }),
    terser({ module: true, compress: { passes: 3 }, mangle: true }),
  ],
}));
