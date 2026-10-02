import { Rt$template, Rt$safeUrl } from "./_platform/Rt.mjs";
const DomConstantUrl$t3 = Rt$template("<nav><a href=\"#/\">All</a><a href>none</a><a>nbsp", 0);
const DomConstantUrl$k3 = { m: (v$1, cx$2) => {
  const r$3 = DomConstantUrl$t3();
  const w$4 = r$3.firstChild.nextSibling.nextSibling;
  w$4.setAttribute("href", Rt$safeUrl(v$1[0]));
  return { s: r$3, q: null, e: r$3 };
}, p: (i$5, v$6) => {
} };
const DomConstantUrl$links = { t: DomConstantUrl$k3, v: [" javascript:x"] };
export { DomConstantUrl$links };
//# sourceMappingURL=DomConstantUrl.mjs.map
