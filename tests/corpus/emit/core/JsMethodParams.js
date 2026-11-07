const JsMethodParams$add = function(a$2, b$3) {
  const self$1 = this;
  return self$1.n + a$2 + b$3;
};
const JsMethodParams$keep = function(v$2) {
  const self$1 = this;
  self$1.kept = v$2;
  return self$1;
};
const JsMethodParams$later = function(step$2) {
  const self$1 = this;
  return () => self$1.base + step$2;
};
export { JsMethodParams$add, JsMethodParams$keep, JsMethodParams$later };
//# sourceMappingURL=JsMethodParams.mjs.map
