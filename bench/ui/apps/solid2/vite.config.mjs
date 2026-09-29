// Solid 2's production build of one page, `ENTRY` (bench, static or
// helpers): one self-contained ES module minified with terser, as research
// 29 §4.2 built its port. One build per page, so no page shares a chunk.
import solid from "@solidjs/vite-plugin";
import { defineConfig } from "vite";

const entry = process.env.ENTRY ?? "bench";

export default defineConfig({
  plugins: [solid()],
  build: {
    outDir: "../../out/solid2",
    emptyOutDir: false,
    minify: "terser",
    modulePreload: false,
    rollupOptions: {
      input: { [entry]: `src/${entry}.jsx` },
      output: { entryFileNames: "[name].js", format: "es", codeSplitting: false },
    },
  },
});
