export const grow = xs => { xs.push(xs.length + 1); return xs; };
export const row = xs => { xs[0] += 1; return xs; };
export const record = x => { x.count += 1; return x; };
export const rekey = x => { x.id += 1; x.count += 1; return x; };
