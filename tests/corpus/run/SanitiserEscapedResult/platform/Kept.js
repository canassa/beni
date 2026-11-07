let box = [];
export const keep = (xs) => { box = xs; };
export const kept = (_) => box.join(",");
export const ident = (x) => x;
