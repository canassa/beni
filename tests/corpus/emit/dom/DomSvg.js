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
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = (n$2) => n$2;
    const $made$6 = { m: ($item$7, $position$8, $cx$9) => {
      const $r$10 = DomSvg$t39();
      return { s: $r$10, q: null, e: $r$10, w0: $r$10, a0: undefined, x: undefined };
    }, p: ($i$11, $item$12, $position$13) => {
      const $t$14 = String$fromInt($item$12);
      if ($t$14 !== $i$11.a0) {
        $i$11.w0.setAttribute("height", $t$14);
        $i$11.a0 = $t$14;
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed($i$1.c0, $input$3, $t$5, $made$6, null);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomSvg$t41 = Rt$templateOf("<svg><g></svg>", 2);
const DomSvg$k41 = { m: ($v$15, $cx$16) => {
  const $r$17 = DomSvg$t41();
  const $c$18 = Rt$slot($r$17, null, $cx$16);
  const $i$19 = { s: $r$17, q: null, e: $r$17, c0: $c$18, g0_0: NaN };
  DomSvg$p41($i$19, $v$15);
  return $i$19;
}, p: DomSvg$p41, l: true };
const DomSvg$picture = (box$1, link$2) => ({ t: DomSvg$k10, v: [box$1, link$2] });
const DomSvg$dot = (x$1) => ({ t: DomSvg$k18, v: [x$1] });
const DomSvg$pair = DomSvg$b22;
const DomSvg$bars = (ns$1) => ({ t: DomSvg$k41, v: [ns$1] });
export { DomSvg$picture, DomSvg$dot, DomSvg$pair, DomSvg$bars };
//# sourceMappingURL=DomSvg.mjs.map
