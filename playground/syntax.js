// A small beni grammar for the playground's editor (docs/design/playground.md
// §4.2): a tokenizer for CodeMirror's `StreamLanguage`, for highlighting
// only. The compiler's diagnostics, not this file, say what is wrong.
//
// It follows language.md §2: line comments (`--`, `--|`, `--!`), strings
// with `${…}` interpolation, `\\` multiline lines, character literals,
// numbers (§2.5: no underscores), the fifteen keywords, the contextual
// `schema` (before a type name) and `where` (before a `name.method`), and
// the Unicode notation (§12.7–§12.10). Markup follows frontend.md §9.1 and
// §9.3, in three modes:
//   - in code, a `<` followed by a letter or `>` opens a tag where an
//     operand may start, and is a comparison after a token that ends one;
//     `</` always closes one;
//   - in a tag, names are attributes, `{…}` is a hole of code, and `>` or
//     `/>` ends it;
//   - between an element's tags (its children), text is text, `<` before a
//     letter or `>` always opens a tag, `</` closes the element, and `{…}`
//     is a hole of code.
//
// It depends on nothing: `token(stream, state)` reads a stream with the
// `StringStream` methods it uses, so a test can drive it without CodeMirror.

const keywords = new Set([
  "if", "then", "else", "case", "of", "let", "in", "type", "alias", "pub",
  "opaque", "import", "as", "exposing", "foreign",
]);

const operator = /^(?:→|←|≠|≤|≥|▷|◁|…|×|λ|\+\+|==|&&|\|\||\/\/|[-+*/^<>=|?:\\])/;

/// A new tokenizer state.
export function startState() {
  return {
    // What the tokenizer is inside, innermost last: `{ kind: "string" }`;
    // `{ kind: "code", depth }` for an interpolation or a markup hole;
    // `{ kind: "tag", closing }` for the inside of a tag; and
    // `{ kind: "children" }` for an element's content.
    stack: [],
    // Whether the last token can end an operand, so that a `<` after it is
    // a comparison and not markup (frontend.md §9.3).
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
  if (frame !== undefined && frame.kind === "children") return childrenPart(stream, state);
  if (stream.eatSpace()) return null;
  if (frame !== undefined && frame.kind === "tag") return tagPart(stream, state);

  // A multiline string line: `\\` first on its line.
  if (stream.column() === stream.indentation() && stream.match("\\\\")) {
    stream.skipToEnd();
    state.endsOperand = true;
    return "string";
  }
  if (stream.match("--")) return comment(stream);
  if (stream.eat('"')) {
    state.stack.push({ kind: "string" });
    return "string";
  }
  if (stream.match(/^'(?:\\(?:u\{[0-9a-fA-F]+\}|.)|[^'\\])'/)) {
    state.endsOperand = true;
    return "string";
  }
  if (stream.match(/^(?:0x[0-9A-Fa-f]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/)) {
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
      if (frame.depth !== 0) {
        state.endsOperand = true;
        return "brace";
      }
      state.stack.pop();
      // The `}` that closes an interpolation goes back into its string.
      const outer = top(state);
      if (outer !== undefined && outer.kind === "string") return "meta";
      state.endsOperand = false;
      return "brace";
    }
  }
  if (openTag(stream, state, !state.endsOperand)) return "tagName";
  if (stream.match(/^schema(?=\s+[A-Z])/) || stream.match(/^where(?=\s+[a-z]\w*\.)/)) {
    state.endsOperand = false;
    return "keyword";
  }
  if (stream.match(/^[a-z_][A-Za-z0-9_]*/)) {
    const keyword = keywords.has(stream.current());
    state.endsOperand = !keyword;
    return keyword ? "keyword" : "variableName";
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
    // `?` ends an operand (§9.3); every other operator expects one.
    state.endsOperand = stream.current() === "?";
    return "operator";
  }
  const ch = stream.next();
  state.endsOperand = ch === ")" || ch === "]" || ch === "}";
  if (ch === "{") return "brace";
  return ch === "(" || ch === ")" || ch === "[" || ch === "]" || ch === "}" ? "paren" : "punctuation";
}

/// A tag's start, when the stream is at one: `</name` or `</>` always, and
/// `<name` or `<>` when `opens` says a tag may open here. Pushes the tag's
/// frame; a closing tag first leaves the children it closes.
function openTag(stream, state, opens) {
  if (stream.match(/^<\/(?:[A-Za-z][\w.]*)?/)) {
    if (top(state)?.kind === "children") state.stack.pop();
    state.stack.push({ kind: "tag", closing: true });
    return true;
  }
  if (opens && stream.match(/^<(?:[A-Za-z][\w.]*|(?=>))/)) {
    state.stack.push({ kind: "tag", closing: false });
    return true;
  }
  return false;
}

/// A line comment from its `--` (already read) to the end of the line.
function comment(stream) {
  const doc = stream.peek() === "|" || stream.peek() === "!";
  stream.skipToEnd();
  return doc ? "docComment" : "lineComment";
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

/// The inside of a tag: comments, attribute names, `=`, values, holes, and
/// the `>` or `/>` that ends it. An opening tag's `>` starts its children; a
/// closing tag's `>` and a `/>` end an operand.
function tagPart(stream, state) {
  const frame = top(state);
  if (stream.match("/>") || stream.eat(">")) {
    state.stack.pop();
    if (!frame.closing && stream.current() === ">") {
      state.stack.push({ kind: "children" });
    } else {
      state.endsOperand = true;
    }
    return "tagName";
  }
  if (stream.match("--")) return comment(stream);
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

/// An element's children: text up to a tag or a hole.
function childrenPart(stream, state) {
  if (openTag(stream, state, true)) return "tagName";
  if (stream.eat("{")) {
    state.stack.push({ kind: "code", depth: 1 });
    state.endsOperand = false;
    return "brace";
  }
  while (!stream.eol() && !stream.match(/^<[A-Za-z/>]/, false) && stream.peek() !== "{") stream.next();
  return "content";
}

/// The definition `StreamLanguage.define` takes.
export const beni = {
  name: "beni",
  startState,
  copyState,
  token,
  languageData: { commentTokens: { line: "--" } },
};
