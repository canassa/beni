// The sibling JavaScript of `String.beni` (docs/design/boundary.md §4).
//
// A `String` is a native JavaScript string (backend.md §4) and a `Char` is a
// one-scalar string. Where the UTF-16 mismatch would show — `length`,
// `slice`, `toList`, `indexes`, and `split` on an empty separator — these
// functions work in CODE POINTS, because the beni API is defined over
// characters and a surrogate half is not one. That is the "core's API
// exposes codepoints where the UTF-16 mismatch would show" half of §4's
// string row, and it is the reason `length` is not `.length`.
//
// `indexes` is the one whose units are visible from OUTSIDE core: its
// answers are indices a caller hands back to `slice`, so counting them in
// code units was a wrong answer at exit 0 rather than an internal detail.

const nil = { $: 0, a: null, b: null };

const fromArray = (items) => {
  let out = nil;
  for (let i = items.length - 1; i >= 0; i--) out = { $: 1, a: items[i], b: out };
  return out;
};

const toArray = (list) => {
  const items = [];
  for (let at = list; at.$ === 1; at = at.b) items.push(at.a);
  return items;
};

const codePoints = (s) => Array.from(s);

export const length = (s) => codePoints(s).length;

// The string comes first (subject first, String.beni). Indexes are code
// points, and a negative index counts from the end
// (String.beni: `slice "snakes on a plane!" 0 (-7) == "snakes on a"`).
export const slice = (s, start, end) => {
  const points = codePoints(s);
  const n = points.length;
  const from = start < 0 ? Math.max(0, n + start) : Math.min(start, n);
  const to = end < 0 ? Math.max(0, n + end) : Math.min(end, n);
  return to <= from ? "" : points.slice(from, to).join("");
};

export const append = (a, b) => a + b;

// Lexicographic by Unicode scalar value, which is what `<` on JavaScript
// strings is NOT (it compares UTF-16 code units, so an astral character
// sorts below U+E000). `Order` has only nullary constructors, so it is a
// bare tag string.
export const compare = (a, b) => {
  const x = codePoints(a);
  const y = codePoints(b);
  const shared = Math.min(x.length, y.length);
  for (let i = 0; i < shared; i++) {
    const cx = x[i].codePointAt(0);
    const cy = y[i].codePointAt(0);
    if (cx < cy) return "LT";
    if (cx > cy) return "GT";
  }
  if (x.length < y.length) return "LT";
  if (x.length > y.length) return "GT";
  return "EQ";
};

export const toUpper = (s) => s.toUpperCase();
export const toLower = (s) => s.toLowerCase();
export const trim = (s) => s.trim();
export const trimLeft = (s) => s.trimStart();
export const trimRight = (s) => s.trimEnd();

export const words = (s) => {
  const parts = s.split(/\s+/).filter((w) => w.length !== 0);
  return fromArray(parts);
};

export const lines = (s) => fromArray(s.split(/\r\n|\r|\n/));

// Subject first: the string being split, then the separator.
//
// An EMPTY separator splits into characters, and `"a😀b".split("")` in
// JavaScript is four code units — two of them surrogate halves, neither of
// them a character. That is the one separator for which the UTF-16 mismatch
// shows, so it is answered in code points like everything else here.
export const split = (s, separator) => {
  if (separator.length === 0) return fromArray(codePoints(s));
  return fromArray(s.split(separator));
};

// Subject first: the string being searched, then the needle.
//
// The answers are CODE POINT indices, so they can be fed straight back to
// `slice`, which is the whole reason anyone calls this. `indexOf` counts
// UTF-16 code units, so each match is translated — by one forward walk that
// carries its position between matches, never a rescan per match, so the
// whole call stays linear in the haystack.
//
// Two rules that are choices rather than consequences, both Elm's
// (`_String_indexes`): an empty needle matches NOTHING, and matches do not
// overlap — the search resumes past the match it found, so
// `indexes "aaaa" "aa"` is `[ 0, 2 ]`. A combining mark is a code point of
// its own, so `indexes "éx" "x"` is `[ 2 ]` and not `[ 1 ]`.
export const indexes = (haystack, needle) => {
  if (needle.length === 0) return nil;
  const found = [];
  // `scanned` is a UTF-16 offset and `point` the number of code points
  // before it. Both only ever move forward.
  let scanned = 0;
  let point = 0;
  let at = haystack.indexOf(needle);
  while (at !== -1) {
    while (scanned < at) {
      scanned += haystack.codePointAt(scanned) > 0xffff ? 2 : 1;
      point += 1;
    }
    // `scanned > at` means the match began on the low half of a surrogate
    // pair, which is a position no character occupies: it has no code point
    // index, so it is not one of the answers.
    if (scanned === at) found.push(point);
    at = haystack.indexOf(needle, at + needle.length);
  }
  return fromArray(found);
};

// Every specification-defined failure is a constructor (§4.1), so a string
// that is not a number comes back as `Nothing` and never as a NaN pretending
// to be an `Int`. `Maybe` has an argument-taking constructor, so both of its
// constructors are padded to one shape.
export const toInt = (s) => {
  if (!/^[+-]?\d+$/.test(s)) return { $: "Nothing", a: null };
  const n = Number(s);
  return Number.isSafeInteger(n) ? { $: "Just", a: n } : { $: "Nothing", a: null };
};

export const fromInt = (n) => String(n);

export const toFloat = (s) => {
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return { $: "Nothing", a: null };
  const n = Number(s);
  return Number.isNaN(n) ? { $: "Nothing", a: null } : { $: "Just", a: n };
};

export const fromFloat = (n) => {
  // `String(1.0)` is "1" in JavaScript and `1` is not a float literal in
  // beni's own syntax, so a whole float prints with its point.
  if (Number.isFinite(n) && Number.isInteger(n)) return `${n}.0`;
  return String(n);
};

export const fromChar = (c) => c;
export const toList = (s) => fromArray(codePoints(s));
export const fromList = (list) => toArray(list).join("");
