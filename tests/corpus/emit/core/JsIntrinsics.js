const JsIntrinsics$read = (o$1) => o$1.firstChild;
const JsIntrinsics$readIndexed = (o$1, k$2) => o$1["x-y"][k$2];
const JsIntrinsics$write = (o$1, v$2) => {
  o$1.$$root = v$2;
  return null;
};
const JsIntrinsics$insert = (parent$1, node$2, before$3) => parent$1.insertBefore(node$2, before$3);
const JsIntrinsics$make = (tag$1) => globalThis.document.createElement.call(globalThis.document, tag$1);
const JsIntrinsics$tests = (a$1, b$2) => [a$1 === b$2, a$1 === null, a$1 === undefined, a$1 == null];
const JsIntrinsics$flag = (flags$1) => (flags$1 & 2) !== 0;
const JsIntrinsics$pair = (x$1) => [x$1, null, undefined];
const JsIntrinsics$callback = (f$1) => f$1((n$2) => n$2 + 1);
const JsIntrinsics$back = (v$1) => v$1;
const JsIntrinsics$second = (xs$1) => xs$1[1];
const JsIntrinsics$fail = (message$1) => {
  throw globalThis.Error(message$1);
};
const JsIntrinsics$store = (xs$1, k$2, v$3) => {
  xs$1[k$2] = v$3;
  return null;
};
export { JsIntrinsics$read, JsIntrinsics$readIndexed, JsIntrinsics$write, JsIntrinsics$insert, JsIntrinsics$make, JsIntrinsics$tests, JsIntrinsics$flag, JsIntrinsics$pair, JsIntrinsics$callback, JsIntrinsics$back, JsIntrinsics$second, JsIntrinsics$fail, JsIntrinsics$store };
//# sourceMappingURL=JsIntrinsics.mjs.map
