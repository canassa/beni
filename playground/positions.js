// Where a beni diagnostic is in the editor (docs/design/playground.md §4.2).
//
// A diagnostic's span (`--diagnostics=json`, frontend.md §1.1) gives a
// 1-based line and column for its start and its end, the end exclusive, and
// a column counts code points (language.md §12.7–§12.9). The editor counts
// UTF-16 units, so `→` is one column and one unit, and a character past
// U+FFFF is one column and two units.

/// The UTF-16 offset in `text` of 1-based `line` and `col`. A position past
/// the end of its line is the end of the line; past the last line, the end
/// of the text.
export function offsetOf(text, line, col) {
  let at = 0;
  for (let l = 1; l < line; l += 1) {
    const newline = text.indexOf("\n", at);
    if (newline === -1) return text.length;
    at = newline + 1;
  }
  for (let c = 1; c < col && at < text.length && text[at] !== "\n"; c += 1) {
    at += text.codePointAt(at) > 0xffff ? 2 : 1;
  }
  return at;
}

/// The range in `text` of a diagnostic's `span`: `{ from, to }`, with `to`
/// never before `from`.
export function rangeOf(text, span) {
  const from = offsetOf(text, span.start.line, span.start.col);
  const to = offsetOf(text, span.end.line, span.end.col);
  return { from, to: Math.max(from, to) };
}
