const JsRef$template = (html$1) => {
  let node$2 = null;
  return () => {
    if (node$2 === null) {
      const t$3 = globalThis.document.createElement("template");
      t$3.innerHTML = html$1;
      node$2 = t$3.content.firstChild;
    }
    return node$2.cloneNode(true);
  };
};
let JsRef$scheduled = false;
const JsRef$flush = () => {
  JsRef$scheduled = false;
  return null;
};
const JsRef$schedule = () => {
  if (JsRef$scheduled) {
    return null;
  } else {
    JsRef$scheduled = true;
    globalThis.queueMicrotask(() => JsRef$scheduled ? JsRef$flush() : null);
    return null;
  }
};
const JsRef$cell = (n$1) => ({ v: n$1 });
const JsRef$bump = (r$1) => {
  r$1.v = r$1.v + 1;
  return null;
};
const JsRef$counted = (n$1) => {
  const r$2 = JsRef$cell(n$1);
  JsRef$bump(r$2);
  return r$2.v;
};
export { JsRef$template, JsRef$flush, JsRef$schedule, JsRef$cell, JsRef$bump, JsRef$counted };
//# sourceMappingURL=JsRef.mjs.map
