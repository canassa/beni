// The playground's editor (docs/design/playground.md §4.2): CodeMirror 6
// from a CDN, each package at the version `index.html`'s import map pins,
// with beni's grammar (`syntax.js`) and the compiler's diagnostics as lint
// marks at their positions (`positions.js`).
import { EditorSelection, EditorState, Transaction } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { HighlightStyle, StreamLanguage, bracketMatching, indentOnInput, indentUnit, syntaxHighlighting } from "@codemirror/language";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { lintGutter, setDiagnostics } from "@codemirror/lint";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { tags } from "@lezer/highlight";
import { beni } from "./syntax.js";
import { rangeOf } from "./positions.js";

// Colours from `style.css`, so that a dark page gets dark colours.
const highlight = HighlightStyle.define([
  { tag: tags.keyword, color: "var(--syntax-keyword)" },
  { tag: [tags.lineComment, tags.docComment], color: "var(--syntax-comment)", fontStyle: "italic" },
  { tag: tags.string, color: "var(--syntax-string)" },
  { tag: tags.meta, color: "var(--syntax-operator)" },
  { tag: tags.escape, color: "var(--syntax-escape)" },
  { tag: [tags.number, tags.bool, tags.atom], color: "var(--syntax-number)" },
  { tag: tags.typeName, color: "var(--syntax-type)" },
  { tag: tags.operator, color: "var(--syntax-operator)" },
  { tag: tags.propertyName, color: "var(--syntax-property)" },
  { tag: [tags.tagName, tags.angleBracket], color: "var(--syntax-tag)" },
  { tag: tags.attributeName, color: "var(--syntax-attribute)" },
]);

const theme = EditorView.theme({
  "&": { height: "100%", backgroundColor: "var(--bg)", color: "var(--fg)" },
  ".cm-scroller": { fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', fontSize: "13px", lineHeight: "1.45" },
  ".cm-gutters": { backgroundColor: "var(--panel)", color: "var(--muted)", borderRight: "1px solid var(--line)" },
  ".cm-activeLine, .cm-activeLineGutter": { backgroundColor: "var(--active)" },
  "&.cm-focused": { outline: "none" },
});

/// An editor in `parent` holding `text`; `changed(byUser)` runs after each
/// change of the text, with `byUser` true when a person made it (typing,
/// pasting, undo) and false when the page did (`replaceText`).
export function createEditor(parent, text, changed) {
  return new EditorView({
    parent,
    state: EditorState.create({
      doc: text,
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        history(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        closeBrackets(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        // beni refuses a tab character anywhere (language.md §2.1): the Tab
        // key indents with four spaces.
        indentUnit.of("    "),
        EditorState.tabSize.of(4),
        StreamLanguage.define(beni),
        syntaxHighlighting(highlight),
        lintGutter(),
        keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, indentWithTab]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) changed(update.transactions.some((tr) => tr.annotation(Transaction.userEvent) !== undefined));
        }),
        theme,
      ],
    }),
  });
}

/// The editor's text.
export function textOf(view) {
  return view.state.doc.toString();
}

/// Replace the editor's text, as one edit that undo can take back.
export function replaceText(view, text) {
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: EditorSelection.cursor(0) });
}

/// Mark `diagnostics` (the compiler's JSON, those in `Main.beni`) in the
/// editor, which holds the text they were made from.
export function markDiagnostics(view, diagnostics) {
  const text = textOf(view);
  const marks = diagnostics.map((d) => ({
    ...rangeOf(text, d.span),
    severity: d.severity === "warning" ? "warning" : "error",
    source: d.code,
    message: `${d.title}\n\n${d.message}`,
  }));
  view.dispatch(setDiagnostics(view.state, marks));
}

/// Select the range of `span` and show it.
export function reveal(view, span) {
  const { from, to } = rangeOf(textOf(view), span);
  view.dispatch({ selection: EditorSelection.range(from, to), scrollIntoView: true });
  view.focus();
}
