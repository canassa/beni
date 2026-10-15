const Basics$plain = (xs$1) => globalThis.Array.isArray(xs$1) ? xs$1 : xs$1.$plain();
const Basics$append = (a$1, b$2) => {
  if (typeof a$1 === "string") {
    const s$3 = a$1;
    const t$4 = b$2;
    return s$3 + t$4;
  } else {
    return Basics$plain(a$1).concat(Basics$plain(b$2));
  }
};
const Basics$toFloat = (n$1) => n$1;
const Basics$min = (x$1, y$2) => x$1 < y$2 ? x$1 : y$2;
const Basics$identity = (a$1) => a$1;
export { Basics$append, Basics$toFloat, Basics$min, Basics$identity };
//# sourceMappingURL=Basics.mjs.map
