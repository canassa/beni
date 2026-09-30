import { Rt$template } from "./_platform/Rt.mjs";
const DomCustomElement$t7 = Rt$template("<my-widget><x-a-b>hi", 1);
const DomCustomElement$k7 = { m: (v$1, cx$2) => {
  const r$3 = DomCustomElement$t7();
  r$3.setAttribute("title", v$1[0]);
  return { s: r$3, q: null, e: r$3, w0: r$3, a0: v$1[0] };
}, p: (i$4, v$5) => {
  if (v$5[0] !== i$4.a0) {
    i$4.w0.setAttribute("title", v$5[0]);
    i$4.a0 = v$5[0];
  }
} };
const DomCustomElement$view = (s$1) => ({ t: DomCustomElement$k7, v: [s$1] });
export { DomCustomElement$view };
