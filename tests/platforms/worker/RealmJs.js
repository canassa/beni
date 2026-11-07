export const siblingDocument = (_) => String(globalThis.document.title);
export const siblingFunction = (_) => String(Function("return 1")());
export const siblingTemplate = (_) => `${globalThis.screen.width}`;
export const siblingImportScripts = (_) => String(globalThis.importScripts("/x.js"));
export const siblingSafe = (document) => {
  const event = typeof document;
  if (globalThis.document !== undefined) return "document";
  return `${globalThis.location.href.startsWith("http") ? "href" : "no href"},${event}`;
};
