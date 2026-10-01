// Replaces the page's `fetch` with one that rejects with a `RangeError`,
// a failure `Http`'s sibling does not name.
export const breakFetch = (unit) => {
  globalThis.fetch = () => Promise.reject(new RangeError("the network fell over"));
  return unit;
};
