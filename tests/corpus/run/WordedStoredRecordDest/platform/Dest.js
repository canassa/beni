export const intoRec = (r, v) => { r.items = r.items.concat([v, v]); return r; };
export const intoIntRec = (n, v) => ({ items: [v, v] });
