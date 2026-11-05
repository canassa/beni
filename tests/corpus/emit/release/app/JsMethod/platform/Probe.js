export const viewPlain = () => function () { const self = this; if (self.p === null) self.p = self.b.slice(self.o); return self.p; };
export const size = () => function () { return this.length; };
export const later = () => function () { const self = this; return () => self.length; };
