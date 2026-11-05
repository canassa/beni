export const counter = start => ({ n: start, bump: function () { const n = this.n; this.n = n + 1; return n + 1; } });
export const nestedObject = k => ({ k, twice: function () { const self = this; const read = () => self.k; return read() + read(); } });
export const outer = () => ({ name: "outer", make: function () { const self = this; return { name: "inner", outerName: self.name, own: function () { return this.name; } }; } });
export const cachedObject = () => ({ p: null, runs: 0, plain: function () { const self = this; if (self.p === null) { self.runs++; self.p = "made"; } return self.p; } });
