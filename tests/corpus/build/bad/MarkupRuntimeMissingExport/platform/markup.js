// The `ssr` runtime without `escape`.
export const escapeAttr = (value) => value;
export const safeUrl = (url) => url;
export const list = (items, row, fallback) => "";
export const classes = (entries) => "";
export const styles = (entries) => "";
export const rawText = (text, tag) => text;
export const text = (s) => ({ t: s });
export const map = (html, f) => html;
