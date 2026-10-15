// The beni grammar of the playground's editor (docs/design/playground.md
// §4.2): CodeMirror's Elm mode (`@codemirror/legacy-modes`, `mode/elm`,
// vendored), with beni's own tokens in front of it. For highlighting only:
// the compiler's diagnostics, not this file, say what is wrong.
//
// The Elm mode reads what beni writes as Elm does: names, a name at the start
// of a line as a definition, types and constructors, numbers, character
// literals, the ASCII operators and the brackets. In front of it, beni's
// rules (language.md §2) take what Elm does not know or reads otherwise:
//   - strings with `${…}` interpolation and escapes, and `\\` multiline lines;
//   - line comments, `--|` and `--!` as doc comments (beni has no `{-` block
//     comment, so a `{` is always a brace);
//   - the Unicode notation (§12.7–§12.10): `→ ← ≠ ≤ ≥ ▷ ◁ … ×` and `λ` as
//     operators, `⊤` and `⊥` as atoms, `True` and `False` as booleans;
//   - beni's keywords: `pub`, `opaque` and `foreign` are keywords, `module`
//     and `port` are names, `schema` is a keyword before a type name and
//     `where` before a `name.method`;
//   - markup, after frontend.md §9.1 and §9.3, in three modes: in code, a
//     `<` followed by a letter or `>` opens a tag where an operand may start,
//     and is a comparison after a token that ends one; `</` always closes
//     one. In a tag, names are attributes, `{…}` is a hole of code, and `>`
//     or `/>` ends it. Between an element's tags (its children), text is
//     text, `<` before a letter or `>` always opens a tag, `</` closes the
//     element, and `{…}` is a hole of code.
// The Elm mode calls an operator a keyword and a bracket a builtin; this file
// names them as beni's grammar always did.
//
// It imports the vendored Elm mode by its path and nothing else, so a test
// can drive `token(stream, state)` with a stream that has the
// `StringStream` methods it uses, without CodeMirror.
import { elm } from "./vendor/codemirror-legacy-modes-elm.js";

const keywords = new Set([
  "if", "then", "else", "case", "of", "let", "in", "type", "alias", "pub",
  "opaque", "import", "as", "exposing", "foreign",
]);

// Elm's keywords that are names in beni.
const elmOnlyKeywords = new Set(["module", "port", "where"]);

const notation = /^(?:→|←|≠|≤|≥|▷|◁|…|×|λ)/;

/// A new tokenizer state.
export function startState() {
  return {
    // What beni's rules are inside, innermost last: `{ kind: "string" }`;
    // `{ kind: "code", depth }` for an interpolation or a markup hole;
    // `{ kind: "tag", closing }` for the inside of a tag; and
    // `{ kind: "children" }` for an element's content.
    stack: [],
    // Whether the last token can end an operand, so that a `<` after it is
    // a comparison and not markup (frontend.md §9.3).
    endsOperand: false,
    // The Elm mode's own state.
    elm: elm.startState(),
  };
}

export function copyState(state) {
  return { stack: state.stack.map((frame) => ({ ...frame })), endsOperand: state.endsOperand, elm: elm.copyState(state.elm) };
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
  if (frame !== undefined && frame.kind === "code") {
    if (stream.peek() === "{") {
      stream.next();
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
  if (stream.match(notation)) {
    state.endsOperand = false;
    return "operator";
  }
  if (stream.match(/^(?:⊤|⊥)/)) {
    state.endsOperand = true;
    return "atom";
  }
  if (stream.match(/^(?:True|False)\b/)) {
    state.endsOperand = true;
    return "bool";
  }
  if (stream.match(/^schema(?=\s+[A-Z])/) || stream.match(/^where(?=\s+[a-z]\w*\.)/)) {
    state.endsOperand = false;
    return "keyword";
  }
  const word = stream.match(/^[a-z][A-Za-z0-9_]*/, false);
  if (word && keywords.has(word[0])) {
    stream.match(word[0]);
    state.endsOperand = false;
    return "keyword";
  }
  if (word && elmOnlyKeywords.has(word[0])) {
    stream.match(word[0]);
    state.endsOperand = true;
    return stream.start === 0 ? "def" : "variable";
  }
  if (stream.match(/^\.[a-z][A-Za-z0-9_]*/)) {
    state.endsOperand = true;
    return "propertyName";
  }
  // No `{-` block comment in beni: the Elm mode would start one.
  if (stream.peek() === "{") {
    stream.next();
    state.endsOperand = false;
    return "brace";
  }
  return elmToken(stream, state);
}

/// The Elm mode's token, named as beni's grammar names it.
function elmToken(stream, state) {
  const name = elm.token(stream, state.elm);
  const text = stream.current();
  if (name === "builtin") {
    state.endsOperand = text === ")" || text === "]" || text === "}";
    if (text === "(" || text === ")") return "paren";
    if (text === "[" || text === "]") return "squareBracket";
    if (text === "{" || text === "}") return "brace";
    return "punctuation";
  }
  if (name === "keyword") {
    // A run of Elm's symbol characters, or `_`.
    state.endsOperand = text === "?";
    return text === "_" ? "keyword" : "operator";
  }
  state.endsOperand = name === "variable" || name === "def" || name === "type" || name === "number" || name === "string";
  return name;
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
