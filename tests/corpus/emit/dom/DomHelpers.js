import { Rt$template, Rt$insertText, Rt$childHtml, Rt$restate, Rt$slot, Rt$forKeyed, Rt$text } from "./_platform/Rt.mjs";
const DomHelpers$p10 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $input$4 = $v$2[1];
  const $x$5 = $input$3;
  if ($x$5 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$5;
    $i$1.x0.data = $x$5;
  }
  const $x$6 = $input$4;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    $i$1.x1.data = $x$6;
  }
};
const DomHelpers$t10 = Rt$template("<b> <!>");
const DomHelpers$k10 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomHelpers$t10();
  const $w$10 = $r$9.firstChild;
  const $w$11 = $w$10.nextSibling;
  const $x$12 = Rt$insertText($r$9, $w$10, "");
  const $x$13 = Rt$insertText($r$9, $w$11, "");
  const $i$14 = { s: $r$9, q: null, e: $r$9, x0: $x$12, x1: $x$13, g0_0: NaN, g1_0: NaN };
  DomHelpers$p10($i$14, $v$7);
  return $i$14;
}, p: DomHelpers$p10 };
const DomHelpers$p27 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $input$4 = $v$2[1];
  if ($input$3 !== $i$1.g0_0 || $input$4 !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3;
    $i$1.g0_1 = $input$4;
    if ($input$3 !== $i$1.a0_0 || $input$4 !== $i$1.a0_1) {
      $i$1.a0_0 = $input$3;
      $i$1.a0_1 = $input$4;
      Rt$childHtml($i$1.c0, DomHelpers$label($input$3, $input$4));
    } else {
      Rt$restate($i$1.c0);
    }
  } else {
    Rt$restate($i$1.c0);
  }
  if ($i$1.g1 === undefined) {
    $i$1.g1 = true;
    if ($i$1.a1 === undefined) {
      Rt$childHtml($i$1.c1, DomHelpers$label("fixed", 1));
      $i$1.a1 = true;
    } else {
      Rt$restate($i$1.c1);
    }
  } else {
    Rt$restate($i$1.c1);
  }
  $i$1.l = $i$1.c0.l || $i$1.c1.l;
};
const DomHelpers$t27 = Rt$template("<div><!><!>");
const DomHelpers$k27 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomHelpers$t27();
  const $w$8 = $r$7.firstChild;
  const $w$9 = $w$8.nextSibling;
  const $c$10 = Rt$slot($r$7, $w$8, $cx$6);
  const $c$11 = Rt$slot($r$7, $w$9, $cx$6);
  const $i$12 = { s: $r$7, q: null, e: $r$7, c0: $c$10, c1: $c$11, a0_0: undefined, a0_1: undefined, a1: undefined, g0_0: NaN, g0_1: NaN, g1: undefined };
  DomHelpers$p27($i$12, $v$5);
  return $i$12;
}, p: DomHelpers$p27, l: true };
const DomHelpers$t42 = Rt$template("<li>");
const DomHelpers$p44 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  {
    const $made$4 = { o: true, h: [], m: ($item$5, $position$6, $cx$7) => {
      const $r$8 = DomHelpers$t42();
      const $c$9 = Rt$slot($r$8, null, $cx$7);
      Rt$childHtml($c$9, DomHelpers$label($item$5, 0));
      return { s: $r$8, q: null, e: $r$8, c0: $c$9, a0_0: $item$5, l: $c$9.l };
    }, p: ($i$10, $item$11, $position$12) => {
      if ($item$11 !== $i$10.a0_0) {
        $i$10.a0_0 = $item$11;
        Rt$childHtml($i$10.c0, DomHelpers$label($item$11, 0));
      } else {
        Rt$restate($i$10.c0);
      }
      $i$10.l = $i$10.c0.l;
    }, l: true, r: ($i$13) => {
      Rt$restate($i$13.c0);
    }, i: false, f: null };
    Rt$forKeyed($i$1.c0, $input$3, null, $made$4, null);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomHelpers$t44 = Rt$template("<ul>");
const DomHelpers$k44 = { m: ($v$14, $cx$15) => {
  const $r$16 = DomHelpers$t44();
  const $c$17 = Rt$slot($r$16, null, $cx$15);
  const $i$18 = { s: $r$16, q: null, e: $r$16, c0: $c$17 };
  DomHelpers$p44($i$18, $v$14);
  return $i$18;
}, p: DomHelpers$p44, l: true };
const DomHelpers$t69 = Rt$template("<b> ");
const DomHelpers$k69 = { m: ($v$2, $cx$3) => {
  const $r$4 = DomHelpers$t69();
  const $w$5 = $r$4.firstChild;
  $w$5.data = $v$2[0];
  return { s: $r$4, q: null, e: $r$4, w1: $w$5, a0: $v$2[0] };
}, p: ($i$6, $v$7) => {
  if ($v$7[0] !== $i$6.a0) {
    $i$6.a0 = $v$7[0];
    $i$6.w1.data = $v$7[0];
  }
} };
const DomHelpers$p85 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.x0.data = $x$4;
    $i$1.x1.data = $x$4;
  }
};
const DomHelpers$t85 = Rt$template("<i><!><!>");
const DomHelpers$k85 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomHelpers$t85();
  const $w$8 = $r$7.firstChild;
  const $w$9 = $w$8.nextSibling;
  const $x$10 = Rt$insertText($r$7, $w$8, "");
  const $x$11 = Rt$insertText($r$7, $w$9, "");
  const $i$12 = { s: $r$7, q: null, e: $r$7, x0: $x$10, x1: $x$11, g0_0: NaN };
  DomHelpers$p85($i$12, $v$5);
  return $i$12;
}, p: DomHelpers$p85 };
const DomHelpers$p96 = ($i$13, $v$14) => {
  const $input$15 = $v$14[0];
  const $input$16 = $v$14[1];
  const $x$17 = $input$15;
  if ($x$17 !== $i$13.g0_0) {
    $i$13.g0_0 = $x$17;
    const $t$18 = DomHelpers$same(DomHelpers$eq$prim, $input$15, 1);
    Rt$childHtml($i$13.c0, $t$18);
  } else {
    Rt$restate($i$13.c0);
  }
  if ($input$15 !== $i$13.g1_0 || $input$16 !== $i$13.g1_1) {
    $i$13.g1_0 = $input$15;
    $i$13.g1_1 = $input$16;
    const $t$19 = $input$16($input$15);
    Rt$childHtml($i$13.c1, $t$19);
  } else {
    Rt$restate($i$13.c1);
  }
  if ($i$13.g2 === undefined) {
    $i$13.g2 = true;
    const $t$20 = Rt$text("t");
    Rt$childHtml($i$13.c2, $t$20);
  } else {
    Rt$restate($i$13.c2);
  }
  $i$13.l = $i$13.c0.l || $i$13.c1.l || $i$13.c2.l;
};
const DomHelpers$t96 = Rt$template("<div><!><!><!>");
const DomHelpers$k96 = { m: ($v$21, $cx$22) => {
  const $r$23 = DomHelpers$t96();
  const $w$24 = $r$23.firstChild;
  const $w$25 = $w$24.nextSibling;
  const $w$26 = $w$25.nextSibling;
  const $c$27 = Rt$slot($r$23, $w$24, $cx$22);
  const $c$28 = Rt$slot($r$23, $w$25, $cx$22);
  const $c$29 = Rt$slot($r$23, $w$26, $cx$22);
  const $i$30 = { s: $r$23, q: null, e: $r$23, c0: $c$27, c1: $c$28, c2: $c$29, g0_0: NaN, g1_0: NaN, g1_1: NaN, g2: undefined };
  DomHelpers$p96($i$30, $v$21);
  return $i$30;
}, p: DomHelpers$p96, l: true };
const DomHelpers$eq$prim = ($x, $y) => $x === $y;
const DomHelpers$label = (name$1, n$2) => ({ t: DomHelpers$k10, v: [name$1, n$2] });
const DomHelpers$page = (name$1, n$2) => ({ t: DomHelpers$k27, v: [name$1, n$2] });
const DomHelpers$rows = (names$1) => ({ t: DomHelpers$k44, v: [names$1] });
const DomHelpers$same = ($m$0, x$1, y$2) => {
  const $t$1 = $m$0(x$1, y$2) ? "same" : "different";
  return { t: DomHelpers$k69, v: [$t$1] };
};
const DomHelpers$others = (n$1) => {
  function twice$2(m$3) {
    return { t: DomHelpers$k85, v: [m$3] };
  }
  return { t: DomHelpers$k96, v: [n$1, twice$2] };
};
export { DomHelpers$page, DomHelpers$rows, DomHelpers$others };
//# sourceMappingURL=DomHelpers.mjs.map
