// `count` is named in this declaration's parameter list and nowhere else in
// the file, which is what check 3 once read as an unbound reference.
function repeat(piece, count) {
  let out = "";
  for (let i = 0; i < count; i += 1) out += piece;
  return out;
}

export const pad = (text, width) => repeat(" ", width - text.length) + text;
