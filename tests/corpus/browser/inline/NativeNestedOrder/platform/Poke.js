export const burst = (ignored) => {
  const w = globalThis.window;
  w.dispatchEvent(new w.CustomEvent("rr-push", { detail: 1 }));
  w.dispatchEvent(new w.Event("direct"));
  w.dispatchEvent(new w.CustomEvent("rr-push", { detail: 2 }));
  return null;
};
