const JsObject$header = (n$1, h$2, plain$3) => ({ length: n$1, h: h$2, hc: 0, p: null, $plain: plain$3 });
const JsObject$tree = (r$1, s$2) => ({ r: r$1, s: s$2, off: s$2 * 2, tc: 0 });
const JsObject$ordered = (f$1, g$2) => ({ z: f$1(), a: g$2() });
const JsObject$empty = () => ({});
const JsObject$point = (n$1) => ({ h: n$1 + 1, length: n$1 });
export { JsObject$header, JsObject$tree, JsObject$ordered, JsObject$empty, JsObject$point };
//# sourceMappingURL=JsObject.mjs.map
