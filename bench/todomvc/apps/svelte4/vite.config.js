// tastejs/todomvc's examples/svelte/vite.config.js (7c64d8f4cdbd, Svelte 4)
// with what only serves its page left out — the copy of todomvc-common's
// base.js and the `base` path — and the input and output chosen by ENTRY:
// `asis` (the official source, its stylesheet imports removed), `full`
// (asis plus localStorage persistence and the filter read at start) or
// `parity` (full without editing). Vite's defaults otherwise, its default
// minifier included.
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

const entry = process.env.ENTRY ?? 'asis';

export default defineConfig({
    plugins: [svelte()],
    build: {
        outDir: `../../out/svelte4-${entry}`,
        emptyOutDir: true,
        modulePreload: false,
        rollupOptions: {
            input: { bundle: `src/${entry}/index.js` },
            output: { entryFileNames: '[name].js', format: 'es' },
        },
    },
});
