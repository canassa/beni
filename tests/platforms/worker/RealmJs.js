export const siblingDocument = (_) => String(globalThis.document.title);
export const siblingFunction = (_) => String(Function("return 1")());
export const siblingTemplate = (_) => `${globalThis.screen.width}`;
export const siblingImportScripts = (_) => String(globalThis.importScripts("/x.js"));
export const siblingSafe = (document) => {
  const event = typeof document;
  if (globalThis.document !== undefined) return "document";
  return `${globalThis.location.href.startsWith("http") ? "href" : "no href"},${event}`;
};
const shadowDocument = (document) => document;
export const siblingShadowed = (_) => String(shadowDocument(document.title));
export const siblingTimerString = (_) => String(globalThis.setTimeout("postMessage(1)", 0));
export const siblingTimerParam = (code) => String(self.setInterval(code, 1000));
export const siblingScopedSafe = (document) => {
  function inner() {
    var location = "local";
    return location;
  }
  const { self } = { self: "own" };
  const later = () => document;
  globalThis.setTimeout(later, 0);
  return `${typeof document},${inner()},${self}`;
};
