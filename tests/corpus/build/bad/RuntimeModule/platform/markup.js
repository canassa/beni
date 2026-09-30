// The `ssr` runtime's hand-written half: everything but `escape` and `list`,
// which the module `Rt` supplies, and an import of a value `Rt` lacks.
import { escape, missing } from "beni:Rt";

export const escapeAttr = (value) => escape(value);
export const safeUrl = (url) => missing(url);
export const classes = (entries) => "";
export const styles = (entries) => "";
export const rawText = (text, tag) => text;
export const text = (s) => ({ t: s });
export const map = (html, f) => html;
