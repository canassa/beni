export const mkTup = (n) => { const r = { x: n }; return { a: r, b: r }; };
export const mkMixed = (n) => { const r = { x: n }; return { a: r, items: [r] }; };
