import { Js$optNone } from "./_core/Js.mjs";
import { Browser$Host$Node$rendererFirstChild, Browser$Host$Node$rendererNextSibling, Browser$Host$Node$rendererParent, Browser$Host$Node$rendererInsertBefore, Browser$Host$Node$rendererAppend, Browser$Host$Node$rendererRemove, Browser$Host$Node$rendererClone } from "./_core/Browser/Host/Node.mjs";
import { Browser$Host$Document$rendererFragment, Browser$Host$Document$rendererImport, Browser$Host$Document$rendererTemplate, Browser$Host$Document$rendererBody, Browser$Host$Document$rendererText } from "./_core/Browser/Host/Document.mjs";
import { Browser$Host$EventTarget$rendererFromNode } from "./_core/Browser/Host/EventTarget.mjs";
const NativeRenderer$first = (node$1) => {
  const $t$1 = node$1.firstChild;
  return $t$1 === null ? Js$optNone : $t$1;
};
const NativeRenderer$next = (node$1) => {
  const $t$1 = node$1.nextSibling;
  return $t$1 === null ? Js$optNone : $t$1;
};
const NativeRenderer$parent = (node$1) => {
  const $t$1 = node$1.parentNode;
  return $t$1 === null ? Js$optNone : $t$1;
};
const NativeRenderer$insert = (container$1, node$2, before$3) => {
  container$1.insertBefore(node$2, before$3 === Js$optNone ? null : before$3);
  return null;
};
const NativeRenderer$append = (container$1, node$2) => {
  container$1.appendChild(node$2);
  return null;
};
const NativeRenderer$remove = (node$1) => {
  const $t$1 = node$1.parentNode;
  if ($t$1 !== null) {
    $t$1.removeChild(node$1);
  }
  return null;
};
const NativeRenderer$clone = (node$1) => node$1.cloneNode(true);
const NativeRenderer$fragment = () => globalThis.document.createDocumentFragment();
const NativeRenderer$importNode = (node$1) => globalThis.document.importNode(node$1, true);
const NativeRenderer$template = (html$1) => {
  const $t$1 = globalThis.document.createElement("template");
  $t$1.innerHTML = html$1;
  return $t$1.content;
};
const NativeRenderer$body = () => globalThis.document.body;
const NativeRenderer$text = (value$1) => globalThis.document.createTextNode(value$1);
const NativeRenderer$target = (node$1) => node$1;
const NativeRenderer$functions = { append: Browser$Host$Node$rendererAppend, body: Browser$Host$Document$rendererBody, clone: Browser$Host$Node$rendererClone, first: Browser$Host$Node$rendererFirstChild, fragment: Browser$Host$Document$rendererFragment, importNode: Browser$Host$Document$rendererImport, insert: Browser$Host$Node$rendererInsertBefore, next: Browser$Host$Node$rendererNextSibling, parent: Browser$Host$Node$rendererParent, remove: Browser$Host$Node$rendererRemove, target: Browser$Host$EventTarget$rendererFromNode, template: Browser$Host$Document$rendererTemplate, text: Browser$Host$Document$rendererText };
export { NativeRenderer$first, NativeRenderer$next, NativeRenderer$parent, NativeRenderer$insert, NativeRenderer$append, NativeRenderer$remove, NativeRenderer$clone, NativeRenderer$fragment, NativeRenderer$importNode, NativeRenderer$template, NativeRenderer$body, NativeRenderer$text, NativeRenderer$target, NativeRenderer$functions };
//# sourceMappingURL=NativeRenderer.mjs.map
