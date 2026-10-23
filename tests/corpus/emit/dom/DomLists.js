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
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { o: false, h: [true], m: ($item$8, $position$9, $cx$10) => {
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
      const $t$20 = $item$17.label;
      if ($t$19 !== $i$16.a0) {
        $i$16.a0 = $t$19;
        $i$16.w0.classList.toggle("danger", $t$19);
      }
      if ($t$20 !== $i$16.a1) {
        $i$16.a1 = $t$20;
        $i$16.w2.data = $t$20;
      }
    }, i: false, f: null, g: 0, z: $input$3.selected };
    Rt$forKeyed($i$1.c0, $t$4, $t$6, $made$7, [$input$3.selected]);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomLists$t44 = Rt$template("<table><tbody>");
const DomLists$k44 = { m: ($v$21, $cx$22) => {
  const $r$23 = DomLists$t44();
  const $w$24 = $r$23.firstChild;
  const $c$25 = Rt$slot($w$24, null, $cx$22);
  const $i$26 = { s: $r$23, q: null, e: $r$23, c0: $c$25 };
  DomLists$p44($i$26, $v$21);
  return $i$26;
}, p: DomLists$p44, l: true };
const DomLists$t62 = Rt$template("<li>none");
const DomLists$k62 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomLists$t62();
  return { s: $r$8, q: null, e: $r$8 };
}, p: ($i$9, $v$10) => {
} };
const DomLists$b62 = { t: DomLists$k62, v: null };
const DomLists$t58 = Rt$template("<li>. <!>");
const DomLists$t72 = Rt$template("<li>blank");
const DomLists$k72 = { m: ($v$30, $cx$31) => {
  const $r$32 = DomLists$t72();
  return { s: $r$32, q: null, e: $r$32 };
}, p: ($i$33, $v$34) => {
} };
const DomLists$b72 = { t: DomLists$k72, v: null };
const DomLists$p77 = ($i$35, $v$36) => {
  const $input$37 = $v$36[0];
  const $x$38 = $input$37;
  if ($x$38 !== $i$35.g0_0) {
    $i$35.g0_0 = $x$38;
    $i$35.w1.data = $x$38;
  }
};
const DomLists$t77 = Rt$template("<li> ");
const DomLists$k77 = { m: ($v$39, $cx$40) => {
  const $r$41 = DomLists$t77();
  const $w$42 = $r$41.firstChild;
  const $i$43 = { s: $r$41, q: null, e: $r$41, w1: $w$42, g0_0: NaN };
  DomLists$p77($i$43, $v$39);
  return $i$43;
}, p: DomLists$p77 };
const DomLists$p81 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  {
    const $t$4 = $input$3.names;
    const $t$5 = $input$3.names;
    const $t$11 = $input$3.names;
    const $made$12 = { o: true, h: [], m: ($item$13, $position$14, $cx$15) => {
      const $r$16 = DomLists$t58();
      const $w$17 = $r$16.firstChild;
      const $w$18 = $w$17.nextSibling;
      const $x$19 = Rt$insertText($r$16, $w$17, $position$14);
      const $x$20 = Rt$insertText($r$16, $w$18, $item$13);
      return { s: $r$16, q: null, e: $r$16, x0: $x$19, x1: $x$20, a0: $position$14, a1: $item$13 };
    }, p: ($i$21, $item$22, $position$23) => {
      if ($position$23 !== $i$21.a0) {
        $i$21.a0 = $position$23;
        $i$21.x0.data = $position$23;
      }
      if ($item$22 !== $i$21.x) {
        if ($item$22 !== $i$21.a1) {
          $i$21.a1 = $item$22;
          $i$21.x1.data = $item$22;
        }
      }
    }, i: true, f: null };
    Rt$forPosition($i$1.c0, $t$4, $made$12, null);
    const $made$24 = { o: true, h: [true], b: ($item$25, $position$26) => DomLists$viewName($item$25), i: false, f: DomLists$b62 };
    Rt$forKeyed($i$1.c1, $t$5, null, $made$24, [DomLists$viewName]);
    const $made$27 = { o: true, h: [], b: ($item$28, $position$29) => {
      const $t$44 = $item$28 === "" ? DomLists$b72 : { t: DomLists$k77, v: [$item$28] };
      return $t$44;
    }, i: false, f: null };
    Rt$forKeyed($i$1.c2, $t$11, null, $made$27, null);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l || $i$1.c1.w || $i$1.c1.l || $i$1.c2.w || $i$1.c2.l;
};
const DomLists$t81 = Rt$template("<div><ol></ol><ul></ul><ul>");
const DomLists$k81 = { m: ($v$45, $cx$46) => {
  const $r$47 = DomLists$t81();
  const $w$48 = $r$47.firstChild;
  const $w$49 = $w$48.nextSibling;
  const $w$50 = $w$49.nextSibling;
  const $c$51 = Rt$slot($w$48, null, $cx$46);
  const $c$52 = Rt$slot($w$49, null, $cx$46);
  const $c$53 = Rt$slot($w$50, null, $cx$46);
  const $i$54 = { s: $r$47, q: null, e: $r$47, c0: $c$51, c1: $c$52, c2: $c$53 };
  DomLists$p81($i$54, $v$45);
  return $i$54;
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
  {
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
      if ($key$13 !== $i$1.a0k || true || $input$3.selected !== $i$1.a0i0) {
        $i$1.a0k = $key$13;
        $i$1.a0i0 = $input$3.selected;
        Rt$show($i$1.c0, $key$13, $made$14($value$12));
      } else {
        Rt$restate($i$1.c0);
      }
    } else {
      $i$1.a0k = $i$1.c0;
      Rt$hide($i$1.c0, DomLists$b96);
    }
  }
  $i$1.l = $i$1.c0.l;
};
const DomLists$t104 = Rt$templateOf("<!>", 4);
const DomLists$k104 = { m: ($v$27, $cx$28) => {
  const $r$29 = DomLists$t104();
  const $w$30 = $r$29.firstChild;
  const $c$31 = Rt$slot(null, $w$30, $cx$28);
  const $i$32 = { s: null, q: $c$31, e: $w$30, c0: $c$31, a0k: undefined, a0v: undefined, a0i0: undefined };
  DomLists$p104($i$32, $v$27);
  return $i$32;
}, p: DomLists$p104, l: true };
const DomLists$viewName = (name$1) => ({ t: DomLists$k18, v: [name$1] });
const DomLists$table = (model$1) => ({ t: DomLists$k44, v: [model$1] });
const DomLists$lists = (model$1) => ({ t: DomLists$k81, v: [model$1] });
const DomLists$first = (model$1) => ({ t: DomLists$k104, v: [model$1] });
export { DomLists$table, DomLists$lists, DomLists$first };
//# sourceMappingURL=DomLists.mjs.map
