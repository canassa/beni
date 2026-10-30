const TypedBuffer$make = (value$1) => {
  const buffer$2 = [];
  buffer$2.push(value$1);
  return buffer$2;
};
const TypedBuffer$length = (buffer$1) => buffer$1.length;
const TypedBuffer$each = (buffer$1, body$2) => {
  for (const value$3 of buffer$1) {
    body$2(value$3);
  }
  return null;
};
const TypedBuffer$while = (buffer$1, body$2) => {
  for (const value$3 of buffer$1) {
    if (!body$2(value$3)) {
      break;
    }
  }
  return null;
};
export { TypedBuffer$make, TypedBuffer$length, TypedBuffer$each, TypedBuffer$while };
//# sourceMappingURL=TypedBuffer.mjs.map
