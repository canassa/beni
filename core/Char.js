// The sibling JavaScript of `Char.beni` (docs/design/boundary.md §4).
//
// A `Char` is a one-scalar JavaScript string, so `toCode` is `codePointAt`
// and not `charCodeAt`: the second one halves an astral character and
// returns a surrogate, which is not a Unicode scalar value and therefore not
// a `Char`.

export const toCode = (c) => c.codePointAt(0);

// Out of range or a surrogate half is replaced rather than thrown: an
// uncaught throw here would be a well-typed program crashing, which §4.1
// forbids outright. U+FFFD is the Unicode replacement character and is the
// specification's own answer to "this is not a scalar value".
export const fromCode = (n) => {
  if (!Number.isInteger(n) || n < 0 || n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) return "�";
  return String.fromCodePoint(n);
};

export const toUpper = (c) => {
  const upper = c.toUpperCase();
  // A case mapping may lengthen the string (ß uppercases to SS), and a
  // `Char` is one scalar: keep the original when the mapping is not 1:1.
  return Array.from(upper).length === 1 ? upper : c;
};

export const toLower = (c) => {
  const lower = c.toLowerCase();
  return Array.from(lower).length === 1 ? lower : c;
};
