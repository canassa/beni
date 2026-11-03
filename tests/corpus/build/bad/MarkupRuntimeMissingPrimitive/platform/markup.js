// The `ssr` runtime without the `html` primitive `map`.
export const escape = (text) => text;
export const escapeAttr = (value) => value;
export const safeUrl = (url) => url;
export const list = (items, row, fallback) => "";
export const classes = (entries) => "";
export const styles = (entries) => "";
export const rawText = (text, tag) => text;
export const text = (s) => ({ t: s });
// It is the program runtime too, after the lines the diagnostics name:
// since 2026-11-03 `node`'s own runtime is its module `Rt`, which a package
// that names `ssr` with a file of its own shadows (boundary.md §9.2).
export const run = (program) => {};
