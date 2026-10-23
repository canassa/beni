import { Rt$safeUrl, Rt$attrNS, Rt$template, Rt$templateOf, Rt$forKeyed, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomSvg$p10 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $input$4 = $v$2[1];
  const $x$5 = $input$3;
  if ($x$5 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$5;
    $i$1.w0.setAttribute("viewBox", $x$5);
  }
  const $x$6 = $input$4;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    Rt$attrNS($i$1.w3, "http://www.w3.org/1999/xlink", "xlink:href", Rt$safeUrl($x$6));
  }
};
const DomSvg$t10 = Rt$template("<svg><linearGradient id=fade><stop offset=0 stop-color=white></stop></linearGradient><use>");
const DomSvg$k10 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomSvg$t10();
  const $w$10 = $r$9.firstChild.nextSibling;
  const $i$11 = { s: $r$9, q: null, e: $r$9, w0: $r$9, w3: $w$10, g0_0: NaN, g1_0: NaN };
  DomSvg$p10($i$11, $v$7);
  return $i$11;
}, p: DomSvg$p10 };
const DomSvg$p18 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("cx", $x$4);
  }
};
const DomSvg$t18 = Rt$templateOf("<svg><circle r=2></svg>", 2);
const DomSvg$k18 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomSvg$t18();
  const $i$8 = { s: $r$7, q: null, e: $r$7, w0: $r$7, g0_0: NaN };
  DomSvg$p18($i$8, $v$5);
  return $i$8;
}, p: DomSvg$p18 };
const DomSvg$t22 = Rt$templateOf("<svg><line x2=10 y2=10></line><text font-size=3>pair</svg>", 6);
const DomSvg$k22 = { m: ($v$1, $cx$2) => {
  const $r$3 = DomSvg$t22();
  const $w$4 = $r$3.firstChild;
  const $w$5 = $w$4.nextSibling;
  return { s: $w$4, q: null, e: $w$5 };
}, p: ($i$6, $v$7) => {
} };
const DomSvg$b22 = { t: DomSvg$k22, v: null };
const DomSvg$t39 = Rt$templateOf("<svg><rect></svg>", 2);
const DomSvg$p41 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  {
    const $t$4 = (n$2) => n$2;
    const $made$5 = { o: true, h: [], m: ($item$6, $position$7, $cx$8) => {
      const $r$9 = DomSvg$t39();
      return { s: $r$9, q: null, e: $r$9, w0: $r$9, a0: undefined, x: undefined };
    }, p: ($i$10, $item$11, $position$12) => {
      const $t$13 = String$fromInt($item$11);
      if ($t$13 !== $i$10.a0) {
        $i$10.w0.setAttribute("height", $t$13);
        $i$10.a0 = $t$13;
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed($i$1.c0, $input$3, $t$4, $made$5, null);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomSvg$t41 = Rt$templateOf("<svg><g></svg>", 2);
const DomSvg$k41 = { m: ($v$14, $cx$15) => {
  const $r$16 = DomSvg$t41();
  const $c$17 = Rt$slot($r$16, null, $cx$15);
  const $i$18 = { s: $r$16, q: null, e: $r$16, c0: $c$17 };
  DomSvg$p41($i$18, $v$14);
  return $i$18;
}, p: DomSvg$p41, l: true };
const DomSvg$picture = (box$1, link$2) => ({ t: DomSvg$k10, v: [box$1, link$2] });
const DomSvg$dot = (x$1) => ({ t: DomSvg$k18, v: [x$1] });
const DomSvg$pair = DomSvg$b22;
const DomSvg$bars = (ns$1) => ({ t: DomSvg$k41, v: [ns$1] });
export { DomSvg$picture, DomSvg$dot, DomSvg$pair, DomSvg$bars };
//# sourceMappingURL=DomSvg.mjs.map
