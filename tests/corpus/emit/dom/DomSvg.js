import { Rt$safeUrl, Rt$attrNS, Rt$template, Rt$forKeyed, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomSvg$p10 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const $in$4 = v$2[1];
  const x$5 = $in$3;
  if (x$5 !== i$1.g0_0) {
    i$1.g0_0 = x$5;
    i$1.w0.setAttribute("viewBox", x$5);
  }
  const x$6 = $in$4;
  if (x$6 !== i$1.g1_0) {
    i$1.g1_0 = x$6;
    Rt$attrNS(i$1.w3, "http://www.w3.org/1999/xlink", "xlink:href", Rt$safeUrl(x$6));
  }
};
const DomSvg$t10 = Rt$template("<svg><linearGradient id=fade><stop offset=0 stop-color=white></stop></linearGradient><use>", 0);
const DomSvg$k10 = { m: (v$7, cx$8) => {
  const r$9 = DomSvg$t10();
  const w$10 = r$9.firstChild.nextSibling;
  const i$11 = { s: r$9, q: null, e: r$9, w0: r$9, w3: w$10, g0_0: NaN, g1_0: NaN };
  DomSvg$p10(i$11, v$7);
  return i$11;
}, p: DomSvg$p10 };
const DomSvg$p18 = (i$12, v$13) => {
  const $in$14 = v$13[0];
  const x$15 = $in$14;
  if (x$15 !== i$12.g0_0) {
    i$12.g0_0 = x$15;
    i$12.w0.setAttribute("cx", x$15);
  }
};
const DomSvg$t18 = Rt$template("<svg><circle r=2></svg>", 2);
const DomSvg$k18 = { m: (v$16, cx$17) => {
  const r$18 = DomSvg$t18();
  const i$19 = { s: r$18, q: null, e: r$18, w0: r$18, g0_0: NaN };
  DomSvg$p18(i$19, v$16);
  return i$19;
}, p: DomSvg$p18 };
const DomSvg$t22 = Rt$template("<svg><line x2=10 y2=10></line><text font-size=3>pair</svg>", 6);
const DomSvg$k22 = { m: (v$20, cx$21) => {
  const r$22 = DomSvg$t22();
  const w$23 = r$22.firstChild;
  const w$24 = w$23.nextSibling;
  return { s: w$23, q: null, e: w$24 };
}, p: (i$25, v$26) => {
} };
const DomSvg$b22 = { t: DomSvg$k22, v: null };
const DomSvg$t39 = Rt$template("<svg><rect></svg>", 2);
const DomSvg$p41 = (i$27, v$28) => {
  const $in$29 = v$28[0];
  const x$30 = $in$29;
  if (x$30 !== i$27.g0_0) {
    i$27.g0_0 = x$30;
    const $t$31 = (n$2) => n$2;
    const made$32 = { m: (item$33, position$34, cx$35) => {
      const r$36 = DomSvg$t39();
      return { s: r$36, q: null, e: r$36, w0: r$36, a0: undefined, x: undefined };
    }, p: (i$37, item$38, position$39) => {
      const $t$40 = String$fromInt(item$38);
      if ($t$40 !== i$37.a0) {
        i$37.w0.setAttribute("height", $t$40);
        i$37.a0 = $t$40;
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed(i$27.c0, $in$29, $t$31, made$32, null);
  } else {
    Rt$restate(i$27.c0);
  }
  i$27.l = i$27.c0.w || i$27.c0.l;
};
const DomSvg$t41 = Rt$template("<svg><g></svg>", 2);
const DomSvg$k41 = { m: (v$41, cx$42) => {
  const r$43 = DomSvg$t41();
  const c$44 = Rt$slot(r$43, null, cx$42);
  const i$45 = { s: r$43, q: null, e: r$43, c0: c$44, g0_0: NaN };
  DomSvg$p41(i$45, v$41);
  return i$45;
}, p: DomSvg$p41, l: true };
const DomSvg$picture = (box$1, link$2) => ({ t: DomSvg$k10, v: [box$1, link$2] });
const DomSvg$dot = (x$1) => ({ t: DomSvg$k18, v: [x$1] });
const DomSvg$pair = DomSvg$b22;
const DomSvg$bars = (ns$1) => ({ t: DomSvg$k41, v: [ns$1] });
export { DomSvg$picture, DomSvg$dot, DomSvg$pair, DomSvg$bars };
//# sourceMappingURL=DomSvg.mjs.map
