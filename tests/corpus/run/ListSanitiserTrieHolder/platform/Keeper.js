let kept = [];
export const keep = (xs) => {
  kept = xs;
  return xs;
};
export const audit = (_) => {
  (Array.isArray(kept) ? kept : kept.$plain()).slice();
  return [];
};
