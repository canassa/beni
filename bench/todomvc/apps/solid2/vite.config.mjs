// Solid 2's production build of one TodoMVC variant, ENTRY (full or
// parity): Vite with the Solid plugin and Vite's own defaults — its default
// minifier included — as a Vite template ships, one self-contained ES
// module per variant.
import solid from "@solidjs/vite-plugin";
import { defineConfig } from "vite";

const entry = process.env.ENTRY ?? "full";

export default defineConfig({
  plugins: [solid()],
  build: {
    outDir: `../../out/solid2-${entry}`,
    emptyOutDir: true,
    modulePreload: false,
    rollupOptions: {
      input: { bundle: `src/${entry}.jsx` },
      output: { entryFileNames: "[name].js", format: "es", codeSplitting: false },
    },
  },
});
