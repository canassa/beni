let kept = [];
export const keep = (xs) => {
  kept = xs;
  return xs;
};
export const audit = (_) => {
  kept.slice();
  return [];
};
