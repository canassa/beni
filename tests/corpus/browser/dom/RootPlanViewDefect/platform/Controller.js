export const schedule = (_) => {
  for (const delay of [100, 200, 300]) globalThis.setTimeout(() => globalThis.document.body.$$root(true), delay);
  return null;
};
