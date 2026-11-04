// Only static markup and an Html hole are used. The other exports satisfy
// the SSR lowering's arity contract and never run in this ABI fixture.
export const escape = (text) => text;
export const escapeAttr = (text) => text;
export const safeUrl = (url) => url;
export const list = (items, row, fallback) => fallback;
export const classes = (entries) => "";
export const styles = (entries) => "";
export const rawText = (text, tag) => text;
export const run = (program) => console.log(program.b);
