const Tuple$mapFirst = (func$1, $p$1) => {
  const x$2 = $p$1.a;
  const y$3 = $p$1.b;
  return { a: func$1(x$2), b: y$3 };
};
const Tuple$mapSecond = (func$1, $p$2) => {
  const x$2 = $p$2.a;
  const y$3 = $p$2.b;
  return { a: x$2, b: func$1(y$3) };
};
export { Tuple$mapFirst, Tuple$mapSecond };
//# sourceMappingURL=Tuple.mjs.map
