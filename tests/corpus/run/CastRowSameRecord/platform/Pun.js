// `{p: [], q: a}` with the argument's own property names, which a release
// build shortens: the record is at the `Int` field `q`.
export const swapIn = (a) => {
  const [p, q] = Object.keys(a);
  return { [p]: [], [q]: a };
};
