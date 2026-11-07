// The `ssr` runtime's hand-written half: everything but `escape` and `list`,
// which the module `Views` supplies, and an import of a value `Views` lacks.
import { escape, missing } from "beni:Views";

export const escapeAttr = (value) => escape(value);
export const safeUrl = (url) => missing(url);
export const classes = (entries) => "";
export const styles = (entries) => "";
export const rawText = (text, tag) => text;
export const text = (s) => ({ t: s });
export const map = (html, f) => html;
// It is the program runtime too, after the lines the diagnostics name:
// since 2026-11-03 `node`'s own runtime is its module `Rt`, which a package
// that names `ssr` with a file of its own shadows (boundary.md §9.2).
export const run = (program) => {};
