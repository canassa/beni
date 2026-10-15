import { Rt$template, Rt$forKeyed, Rt$restate, Rt$slot, Rt$insertText, Rt$forPosition, Rt$show, Rt$hide, Rt$templateOf } from "./_platform/Rt.mjs";
import { List$head } from "./_core/List.mjs";
const DomLists$p18 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w1.data = $x$4;
  }
};
const DomLists$t18 = Rt$template("<li> ");
const DomLists$k18 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomLists$t18();
  const $w$8 = $r$7.firstChild;
  const $i$9 = { s: $r$7, q: null, e: $r$7, w1: $w$8, g0_0: NaN };
  DomLists$p18($i$9, $v$5);
  return $i$9;
}, p: DomLists$p18 };
const DomLists$t42 = Rt$template("<tr><td> ");
const DomLists$p44 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.rows !== $i$1.g0_0 || $input$3.selected !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3.rows;
    $i$1.g0_1 = $input$3.selected;
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { m: ($item$8, $position$9, $cx$10) => {
      const $t$11 = $item$8.id === $input$3.selected;
      const $t$12 = $item$8.label;
      const $r$13 = DomLists$t42();
      const $w$14 = $r$13.firstChild;
      const $w$15 = $w$14.firstChild;
      if ($t$11) {
        $r$13.classList.toggle("danger", true);
      }
      $w$15.data = $t$12;
      return { s: $r$13, q: null, e: $r$13, w0: $r$13, w2: $w$15, a0: $t$11, a1: $t$12 };
    }, p: ($i$16, $item$17, $position$18) => {
      const $t$19 = $item$17.id === $input$3.selected;
      if ($t$19 !== $i$16.a0) {
        $i$16.a0 = $t$19;
        $i$16.w0.classList.toggle("danger", $t$19);
      }
      if ($item$17 !== $i$16.x) {
        const $t$20 = $item$17.label;
        if ($t$20 !== $i$16.a1) {
          $i$16.a1 = $t$20;
          $i$16.w2.data = $t$20;
        }
      }
    }, i: false, f: null, g: 0, z: $input$3.selected };
    Rt$forKeyed($i$1.c0, $t$4, $t$6, $made$7, [$input$3.selected]);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomLists$t44 = Rt$template("<table><tbody>");
const DomLists$k44 = { m: ($v$21, $cx$22) => {
  const $r$23 = DomLists$t44();
  const $w$24 = $r$23.firstChild;
  const $c$25 = Rt$slot($w$24, null, $cx$22);
  const $i$26 = { s: $r$23, q: null, e: $r$23, c0: $c$25, g0_0: NaN, g0_1: NaN };
  DomLists$p44($i$26, $v$21);
  return $i$26;
}, p: DomLists$p44, l: true };
const DomLists$t62 = Rt$template("<li>none");
const DomLists$k62 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomLists$t62();
  return { s: $r$9, q: null, e: $r$9 };
}, p: ($i$10, $v$11) => {
} };
const DomLists$b62 = { t: DomLists$k62, v: null };
const DomLists$t58 = Rt$template("<li>. <!>");
const DomLists$t72 = Rt$template("<li>blank");
const DomLists$k72 = { m: ($v$31, $cx$32) => {
  const $r$33 = DomLists$t72();
  return { s: $r$33, q: null, e: $r$33 };
}, p: ($i$34, $v$35) => {
} };
const DomLists$b72 = { t: DomLists$k72, v: null };
const DomLists$p77 = ($i$36, $v$37) => {
  const $input$38 = $v$37[0];
  const $x$39 = $input$38;
  if ($x$39 !== $i$36.g0_0) {
    $i$36.g0_0 = $x$39;
    $i$36.w1.data = $x$39;
  }
};
const DomLists$t77 = Rt$template("<li> ");
const DomLists$k77 = { m: ($v$40, $cx$41) => {
  const $r$42 = DomLists$t77();
  const $w$43 = $r$42.firstChild;
  const $i$44 = { s: $r$42, q: null, e: $r$42, w1: $w$43, g0_0: NaN };
  DomLists$p77($i$44, $v$40);
  return $i$44;
}, p: DomLists$p77 };
const DomLists$p81 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.names;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = $input$3.names;
    const $t$6 = $input$3.names;
    const $t$12 = $input$3.names;
    const $made$13 = { m: ($item$14, $position$15, $cx$16) => {
      const $r$17 = DomLists$t58();
      const $w$18 = $r$17.firstChild;
      const $w$19 = $w$18.nextSibling;
      const $x$20 = Rt$insertText($r$17, $w$18, $position$15);
      const $x$21 = Rt$insertText($r$17, $w$19, $item$14);
      return { s: $r$17, q: null, e: $r$17, x0: $x$20, x1: $x$21, a0: $position$15, a1: $item$14 };
    }, p: ($i$22, $item$23, $position$24) => {
      if ($position$24 !== $i$22.a0) {
        $i$22.a0 = $position$24;
        $i$22.x0.data = $position$24;
      }
      if ($item$23 !== $i$22.x) {
        if ($item$23 !== $i$22.a1) {
          $i$22.a1 = $item$23;
          $i$22.x1.data = $item$23;
        }
      }
    }, i: true, f: null };
    Rt$forPosition($i$1.c0, $t$5, $made$13, null);
    const $made$25 = { b: ($item$26, $position$27) => DomLists$viewName($item$26), i: false, f: DomLists$b62 };
    Rt$forKeyed($i$1.c1, $t$6, null, $made$25, [DomLists$viewName]);
    const $made$28 = { b: ($item$29, $position$30) => {
      const $t$45 = $item$29 === "" ? DomLists$b72 : { t: DomLists$k77, v: [$item$29] };
      return $t$45;
    }, i: false, f: null };
    Rt$forKeyed($i$1.c2, $t$12, null, $made$28, null);
  } else {
    Rt$restate($i$1.c0);
    Rt$restate($i$1.c1);
    Rt$restate($i$1.c2);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l || $i$1.c1.w || $i$1.c1.l || $i$1.c2.w || $i$1.c2.l;
};
const DomLists$t81 = Rt$template("<div><ol></ol><ul></ul><ul>");
const DomLists$k81 = { m: ($v$46, $cx$47) => {
  const $r$48 = DomLists$t81();
  const $w$49 = $r$48.firstChild;
  const $w$50 = $w$49.nextSibling;
  const $w$51 = $w$50.nextSibling;
  const $c$52 = Rt$slot($w$49, null, $cx$47);
  const $c$53 = Rt$slot($w$50, null, $cx$47);
  const $c$54 = Rt$slot($w$51, null, $cx$47);
  const $i$55 = { s: $r$48, q: null, e: $r$48, c0: $c$52, c1: $c$53, c2: $c$54, g0_0: NaN };
  DomLists$p81($i$55, $v$46);
  return $i$55;
}, p: DomLists$p81, l: true };
const DomLists$t96 = Rt$template("<p>none");
const DomLists$k96 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomLists$t96();
  return { s: $r$9, q: null, e: $r$9 };
}, p: ($i$10, $v$11) => {
} };
const DomLists$b96 = { t: DomLists$k96, v: null };
const DomLists$t102 = Rt$template("<p> of <!>");
const DomLists$k102 = { m: ($v$18, $cx$19) => {
  const $r$20 = DomLists$t102();
  const $w$21 = $r$20.firstChild;
  const $w$22 = $w$21.nextSibling;
  const $x$23 = Rt$insertText($r$20, $w$21, $v$18[0]);
  const $x$24 = Rt$insertText($r$20, $w$22, $v$18[1]);
  return { s: $r$20, q: null, e: $r$20, x0: $x$23, x1: $x$24, a0: $v$18[0], a1: $v$18[1] };
}, p: ($i$25, $v$26) => {
  if ($v$26[0] !== $i$25.a0) {
    $i$25.a0 = $v$26[0];
    $i$25.x0.data = $v$26[0];
  }
  if ($v$26[1] !== $i$25.a1) {
    $i$25.a1 = $v$26[1];
    $i$25.x1.data = $v$26[1];
  }
} };
const DomLists$p104 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.rows !== $i$1.g0_0 || $input$3.selected !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3.rows;
    $i$1.g0_1 = $input$3.selected;
    const $t$4 = List$head($input$3.rows);
    const $t$6 = ($p$5) => $p$5.id;
    const $made$14 = ($value$15) => {
      const $t$16 = $value$15.label;
      const $t$17 = $input$3.selected;
      return { t: DomLists$k102, v: [$t$16, $t$17] };
    };
    if ($t$4.$ === "Just") {
      const $value$12 = $t$4.a;
      const $key$13 = $t$6($value$12);
      if ($key$13 !== $i$1.a0k || $value$12 !== $i$1.a0v || $input$3.selected !== $i$1.a0i0) {
        $i$1.a0k = $key$13;
        $i$1.a0v = $value$12;
        $i$1.a0i0 = $input$3.selected;
        Rt$show($i$1.c0, $key$13, $made$14($value$12));
      } else {
        Rt$restate($i$1.c0);
      }
    } else {
      $i$1.a0k = $i$1.c0;
      Rt$hide($i$1.c0, DomLists$b96);
    }
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.l;
};
const DomLists$t104 = Rt$templateOf("<!>", 4);
const DomLists$k104 = { m: ($v$27, $cx$28) => {
  const $r$29 = DomLists$t104();
  const $w$30 = $r$29.firstChild;
  const $c$31 = Rt$slot(null, $w$30, $cx$28);
  const $i$32 = { s: null, q: $c$31, e: $w$30, c0: $c$31, a0k: undefined, a0v: undefined, a0i0: undefined, g0_0: NaN, g0_1: NaN };
  DomLists$p104($i$32, $v$27);
  return $i$32;
}, p: DomLists$p104, l: true };
const DomLists$viewName = (name$1) => ({ t: DomLists$k18, v: [name$1] });
const DomLists$table = (model$1) => ({ t: DomLists$k44, v: [model$1] });
const DomLists$lists = (model$1) => ({ t: DomLists$k81, v: [model$1] });
const DomLists$first = (model$1) => ({ t: DomLists$k104, v: [model$1] });
export { DomLists$table, DomLists$lists, DomLists$first };
//# sourceMappingURL=DomLists.mjs.map
