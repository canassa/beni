import { Browser$Host$Array$rendererTruncate, Browser$Host$Array$rendererAt } from "./_core/Browser/Host/Array.mjs";
const ArrayTruncate$shrink = (array$1, length$2) => {
  array$1.length = length$2;
  return null;
};
const ArrayTruncate$read = (array$1, index$2) => {
  if (index$2 !== index$2 >>> 0 || index$2 >= array$1.length) {
    throw new globalThis.RangeError("beni: renderer array index out of bounds");
  }
  return array$1[index$2];
};
const ArrayTruncate$functions = { at: Browser$Host$Array$rendererAt, truncate: Browser$Host$Array$rendererTruncate };
export { ArrayTruncate$shrink, ArrayTruncate$read, ArrayTruncate$functions };
//# sourceMappingURL=ArrayTruncate.mjs.map
