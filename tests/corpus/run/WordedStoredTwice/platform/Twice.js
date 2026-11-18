export const dupW = (a) => [a, a];
export const tripW = (a, b) => [a, b, a];
export const mkW = (n) => { const r = { x: n, xs: [n] }; return [r, r]; };
