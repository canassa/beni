import { Rt$safeUrl, Rt$template } from "./_platform/Rt.mjs";
const DomConstantUrl$p3 = (i$1, v$2) => {
  if (i$1.g0 === undefined) {
    i$1.g0 = true;
    i$1.w5.setAttribute("href", Rt$safeUrl(" javascript:x"));
  }
};
const DomConstantUrl$t3 = Rt$template("<nav><a href=\"#/\">All</a><a href>none</a><a>nbsp", 0);
const DomConstantUrl$k3 = { m: (v$3, cx$4) => {
  const r$5 = DomConstantUrl$t3();
  const w$6 = r$5.firstChild.nextSibling.nextSibling;
  const i$7 = { s: r$5, q: null, e: r$5, w5: w$6, g0: undefined };
  DomConstantUrl$p3(i$7, v$3);
  return i$7;
}, p: DomConstantUrl$p3 };
const DomConstantUrl$b3 = { t: DomConstantUrl$k3, v: null };
const DomConstantUrl$links = DomConstantUrl$b3;
export { DomConstantUrl$links };
//# sourceMappingURL=DomConstantUrl.mjs.map
