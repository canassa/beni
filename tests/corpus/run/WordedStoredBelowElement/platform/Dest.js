export const nest = (l, a) => { l.push([a, a]); return l; };
export const focusNest = (l, i, g) => { const a = g(l[i][0]); l[i] = [a, a]; return l; };
export const consNest = (a, l) => [[a, a], ...l];
