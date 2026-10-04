import { Rt$template } from "./_platform/Rt.mjs";
const DomCustomElement$p7 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3 !== i$1.g0_0) {
    i$1.g0_0 = $in$3;
    if ($in$3 !== i$1.a0) {
      i$1.w0.setAttribute("title", $in$3);
      i$1.a0 = $in$3;
    }
  }
};
const DomCustomElement$t7 = Rt$template("<my-widget><x-a-b>hi", 1);
const DomCustomElement$k7 = { m: (v$4, cx$5) => {
  const r$6 = DomCustomElement$t7();
  const i$7 = { s: r$6, q: null, e: r$6, w0: r$6, a0: undefined, g0_0: undefined };
  DomCustomElement$p7(i$7, v$4);
  return i$7;
}, p: DomCustomElement$p7 };
const DomCustomElement$view = (s$1) => ({ t: DomCustomElement$k7, v: [s$1] });
export { DomCustomElement$view };
//# sourceMappingURL=DomCustomElement.mjs.map
