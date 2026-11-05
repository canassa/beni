export const start = (send) => {
  const handler = () => send(9);
  globalThis.window.addEventListener("direct", handler);
  return (ignored) => { globalThis.window.removeEventListener("direct", handler); return null; };
};
