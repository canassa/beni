// A small beni grammar for the playground's editor (docs/design/playground.md
// §4.2): a tokenizer for CodeMirror's `StreamLanguage`, for highlighting
// only. The compiler's diagnostics, not this file, say what is wrong.
//
// It follows language.md §2: line comments (`--`, `--|`, `--!`), strings
// with `${…}` interpolation, `\\` multiline lines, character literals,
// numbers, the fifteen keywords and the contextual `schema` and `where`, and
// the Unicode notation (§12.7–§12.10). Markup is found as the lexer finds
// it: a `<` followed by a letter is a tag where an operand may start, and a
// comparison after a token that ends one (frontend.md §9.3).
//
// It depends on nothing: `token(stream, state)` reads a stream with the
// `StringStream` methods it uses, so a test can drive it without CodeMirror.

const keywords = new Set([
  "if", "then", "else", "case", "of", "let", "in", "type", "alias", "pub",
  "opaque", "import", "as", "exposing", "foreign", "schema", "where",
]);

const operator = /^(?:→|←|≠|≤|≥|▷|◁|…|×|λ|\+\+|==|&&|\|\||\/\/|[-+*/^<>=|?:\\])/;

/// A new tokenizer state.
export function startState() {
  return {
    // What the tokenizer is inside, innermost last: `{ kind: "string" }`,
    // `{ kind: "code", depth }` for an interpolation or a markup hole, and
    // `{ kind: "tag" }` for the inside of a markup tag.
    stack: [],
    // Whether the last token can end an operand, so that a `<` after it is
    // a comparison and not markup.
    endsOperand: false,
  };
}

export function copyState(state) {
  return { stack: state.stack.map((frame) => ({ ...frame })), endsOperand: state.endsOperand };
}

const top = (state) => state.stack[state.stack.length - 1];

/// One token of `stream`: its highlighting name, or null for none.
export function token(stream, state) {
  const frame = top(state);
  if (frame !== undefined && frame.kind === "string") return stringPart(stream, state);
  if (stream.eatSpace()) return null;
  if (frame !== undefined && frame.kind === "tag") return tagPart(stream, state);

  // A multiline string line: `\\` first on its line.
  if (stream.column() === stream.indentation() && stream.match("\\\\")) {
    stream.skipToEnd();
    state.endsOperand = true;
    return "string";
  }
  if (stream.match("--")) {
    const doc = stream.peek() === "|" || stream.peek() === "!";
    stream.skipToEnd();
    return doc ? "docComment" : "lineComment";
  }
  if (stream.eat('"')) {
    state.stack.push({ kind: "string" });
    return "string";
  }
  if (stream.match(/^'(?:\\(?:u\{[0-9a-fA-F]+\}|.)|[^'\\])'/)) {
    state.endsOperand = true;
    return "string";
  }
  if (stream.match(/^(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)/)) {
    state.endsOperand = true;
    return "number";
  }
  if (frame !== undefined && frame.kind === "code") {
    if (stream.eat("{")) {
      frame.depth += 1;
      state.endsOperand = false;
      return "brace";
    }
    if (stream.peek() === "}") {
      stream.next();
      frame.depth -= 1;
      if (frame.depth === 0) {
        state.stack.pop();
        // The `}` that closes an interpolation goes back into its string.
        const outer = top(state);
        if (outer !== undefined && outer.kind === "string") return "meta";
        state.endsOperand = false;
        return "brace";
      }
      state.endsOperand = true;
      return "brace";
    }
  }
  // Markup: `<name` where an operand may start, and `</name>` anywhere (a
  // `/` cannot start an operand, so `</` is never a comparison).
  if (stream.match(/^<\/[A-Za-z][\w.]*/) || (!state.endsOperand && stream.match(/^<[A-Za-z][\w.]*/))) {
    state.stack.push({ kind: "tag" });
    return "tagName";
  }
  if (stream.match(/^[a-z_][A-Za-z0-9_]*/)) {
    const word = stream.current();
    state.endsOperand = !keywords.has(word) || word === "in";
    if (keywords.has(word)) return "keyword";
    return "variableName";
  }
  if (stream.match(/^[A-Z][A-Za-z0-9_]*/)) {
    state.endsOperand = true;
    const word = stream.current();
    return word === "True" || word === "False" ? "bool" : "typeName";
  }
  if (stream.match(/^\.[a-z][A-Za-z0-9_]*/)) {
    state.endsOperand = true;
    return "propertyName";
  }
  if (stream.match(/^(?:⊤|⊥)/)) {
    state.endsOperand = true;
    return "atom";
  }
  if (stream.match(operator)) {
    state.endsOperand = false;
    return "operator";
  }
  const ch = stream.next();
  state.endsOperand = ch === ")" || ch === "]" || ch === "}";
  if (ch === "{") return "brace";
  return ch === "(" || ch === ")" || ch === "[" || ch === "]" || ch === "}" ? "paren" : "punctuation";
}

/// The inside of a string: up to its closing `"`, an interpolation's `${`,
/// or the end of the line (a string is one line; the lexer reports the
/// rest).
function stringPart(stream, state) {
  if (stream.match("${")) {
    state.stack.push({ kind: "code", depth: 1 });
    state.endsOperand = false;
    return "meta";
  }
  while (!stream.eol()) {
    if (stream.peek() === '"') {
      stream.next();
      state.stack.pop();
      state.endsOperand = true;
      return "string";
    }
    if (stream.match("${", false)) return "string";
    if (stream.peek() === "\\") {
      if (stream.current().length !== 0) return "string";
      stream.next();
      stream.match(/^u\{[0-9a-fA-F]*\}?/) || stream.next();
      return "escape";
    }
    stream.next();
  }
  // A string does not go on to the next line.
  state.stack.pop();
  state.endsOperand = true;
  return "string";
}

/// The inside of a markup tag: attribute names, `=`, values, holes, and the
/// `>` or `/>` that ends it.
function tagPart(stream, state) {
  if (stream.match("/>") || stream.eat(">")) {
    state.stack.pop();
    state.endsOperand = false;
    return "tagName";
  }
  if (stream.match(/^[A-Za-z_][\w-]*/)) return "attributeName";
  if (stream.eat("=")) return "operator";
  if (stream.eat('"')) {
    state.stack.push({ kind: "string" });
    return "string";
  }
  if (stream.eat("{")) {
    state.stack.push({ kind: "code", depth: 1 });
    state.endsOperand = false;
    return "brace";
  }
  stream.next();
  return null;
}

/// The definition `StreamLanguage.define` takes.
export const beni = {
  name: "beni",
  startState,
  copyState,
  token,
  languageData: { commentTokens: { line: "--" } },
};
