// The `ssr` runtime whose `list` takes two parameters where the lowering
// passes three, and whose `map` takes one where the primitive takes two.
export const escape = (text) => text;
export const escapeAttr = (value) => value;
export const safeUrl = (url) => url;
export const list = (items, row) => "";
export const classes = (entries) => "";
export const styles = (entries) => "";
export const rawText = (text, tag) => text;
export const text = (s) => ({ t: s });
export const map = (html) => html;
