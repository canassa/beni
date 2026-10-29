// Solid 2's hydratable build of one page of `bench/ui/hydrate.mjs`, `PAGE`,
// into `OUT`: the client bundle — one self-contained ES module minified with
// terser, as `vite.config.mjs` builds the other pages — and, under
// `vite build --ssr`, the server module whose `renderToString` writes the
// page. `solid({ ssr: true })` is the plugin's transform-only mode:
// hydratable client code and SSR server code, the entries ours.
import solid from "@solidjs/vite-plugin";
import { defineConfig } from "vite";

const page = process.env.PAGE ?? "counter";

export default defineConfig({
  plugins: [solid({ ssr: true })],
  build: {
    outDir: process.env.OUT,
    emptyOutDir: true,
    minify: "terser",
    modulePreload: false,
    rollupOptions: {
      input: { client: `src/hydrate/${page}/client.jsx` },
      output: { entryFileNames: "[name].js", format: "es", codeSplitting: false },
    },
  },
});
