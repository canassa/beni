const JsMethod$viewPlain = function() {
  const self$1 = this;
  const p$2 = self$1.p;
  if (p$2 === null) {
    const c$3 = self$1.b.slice(self$1.o);
    self$1.p = c$3;
    return c$3;
  } else {
    return p$2;
  }
};
const JsMethod$size = function() {
  const self$1 = this;
  return self$1.length;
};
const JsMethod$later = function() {
  const self$1 = this;
  return () => self$1.length;
};
export { JsMethod$viewPlain, JsMethod$size, JsMethod$later };
//# sourceMappingURL=JsMethod.mjs.map
