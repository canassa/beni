export const retain = callback => {
  globalThis.raise = callback;
  return null;
};
