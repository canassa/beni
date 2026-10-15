import { Rt$template, Rt$delegate, Rt$forKeyed, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
import { String$fromInt, String$compare } from "./_core/String.mjs";
const DomRowMount$t57 = Rt$template("<li><a> </a><input>");
const DomRowMount$p59 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.rows !== $i$1.g0_0 || $input$3.picked !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3.rows;
    $i$1.g0_1 = $input$3.picked;
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { m: ($item$8, $position$9, $cx$10) => {
      const $r$11 = DomRowMount$t57();
      const $w$12 = $r$11.firstChild;
      const $w$13 = $w$12.firstChild;
      const $w$14 = $w$12.nextSibling;
      Rt$delegate(["click", "input"]);
      if ($cx$10 !== null) {
        $w$12.$$cx = $cx$10;
      }
      $w$14.$$inputX = Html$targetValue;
      if ($cx$10 !== null) {
        $w$14.$$cx = $cx$10;
      }
      return { s: $r$11, q: null, e: $r$11, w0: $r$11, w1: $w$12, w2: $w$13, w3: $w$14, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, x: undefined };
    }, p: ($i$15, $item$16, $position$17) => {
      const $t$18 = $input$3.picked === $item$16.id ? "on" : "";
      if ($t$18 !== $i$15.a0) {
        $i$15.w0.setAttribute("class", $t$18);
        $i$15.a0 = $t$18;
      }
      if ($item$16 !== $i$15.x) {
        const $t$19 = String$fromInt($item$16.id);
        const $t$20 = { $: "Pick", a: $item$16.id, b: null };
        const $t$21 = $item$16.label;
        const $t$23 = ($p$22) => ({ $: "Typed", a: $item$16.id, b: $p$22 });
        if ($t$19 !== $i$15.a1) {
          $i$15.a1 = $t$19;
          $i$15.w0.style.setProperty("order", $t$19);
        }
        if ($t$20 !== $i$15.a2) {
          $i$15.a2 = $t$20;
          $i$15.w1.$$click = $t$20;
        }
        if ($t$21 !== $i$15.a3) {
          $i$15.a3 = $t$21;
          $i$15.w2.data = $t$21;
        }
        if ($t$23 !== $i$15.a4) {
          $i$15.a4 = $t$23;
          $i$15.w3.$$input = $t$23;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $input$3.picked };
    Rt$forKeyed($i$1.c0, $t$4, $t$6, $made$7, [$input$3.picked]);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomRowMount$t59 = Rt$template("<ul>");
const DomRowMount$k59 = { m: ($v$24, $cx$25) => {
  const $r$26 = DomRowMount$t59();
  const $c$27 = Rt$slot($r$26, null, $cx$25);
  const $i$28 = { s: $r$26, q: null, e: $r$26, c0: $c$27, g0_0: NaN, g0_1: NaN };
  DomRowMount$p59($i$28, $v$24);
  return $i$28;
}, p: DomRowMount$p59, l: true };
const DomRowMount$t89 = Rt$template("<li>");
const DomRowMount$p91 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.rows !== $i$1.g0_0 || $input$3.picked !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3.rows;
    $i$1.g0_1 = $input$3.picked;
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { m: ($item$8, $position$9, $cx$10) => {
      const $t$11 = $item$8.label;
      const $t$12 = $input$3.picked === $item$8.id ? "on" : "";
      const $r$13 = DomRowMount$t89();
      $r$13.setAttribute("title", $t$11);
      $r$13.setAttribute("class", $t$12);
      return { s: $r$13, q: null, e: $r$13, w0: $r$13, a0: $t$11, a1: $t$12 };
    }, p: ($i$14, $item$15, $position$16) => {
      const $t$18 = $input$3.picked === $item$15.id ? "on" : "";
      if ($t$18 !== $i$14.a1) {
        $i$14.w0.setAttribute("class", $t$18);
        $i$14.a1 = $t$18;
      }
      if ($item$15 !== $i$14.x) {
        const $t$17 = $item$15.label;
        if ($t$17 !== $i$14.a0) {
          $i$14.w0.setAttribute("title", $t$17);
          $i$14.a0 = $t$17;
        }
      }
    }, i: false, f: null, g: 0, z: $input$3.picked };
    Rt$forKeyed($i$1.c0, $t$4, $t$6, $made$7, [$input$3.picked]);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomRowMount$t91 = Rt$template("<ul>");
const DomRowMount$k91 = { m: ($v$19, $cx$20) => {
  const $r$21 = DomRowMount$t91();
  const $c$22 = Rt$slot($r$21, null, $cx$20);
  const $i$23 = { s: $r$21, q: null, e: $r$21, c0: $c$22, g0_0: NaN, g0_1: NaN };
  DomRowMount$p91($i$23, $v$19);
  return $i$23;
}, p: DomRowMount$p91, l: true };
const DomRowMount$t115 = Rt$template("<li> ");
const DomRowMount$p117 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.rows !== $i$1.g0_0 || $input$3.picked !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3.rows;
    $i$1.g0_1 = $input$3.picked;
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { m: ($item$8, $position$9, $cx$10) => {
      const $t$11 = $input$3.picked === $item$8.id;
      const $t$12 = $item$8.label;
      const $r$13 = DomRowMount$t115();
      const $w$14 = $r$13.firstChild;
      if ($t$11) {
        $r$13.classList.toggle("on", true);
      }
      $w$14.data = $t$12;
      return { s: $r$13, q: null, e: $r$13, w0: $r$13, w1: $w$14, a0: $t$11, a1: $t$12 };
    }, p: ($i$15, $item$16, $position$17) => {
      const $t$18 = $input$3.picked === $item$16.id;
      if ($t$18 !== $i$15.a0) {
        $i$15.a0 = $t$18;
        $i$15.w0.classList.toggle("on", $t$18);
      }
      if ($item$16 !== $i$15.x) {
        const $t$19 = $item$16.label;
        if ($t$19 !== $i$15.a1) {
          $i$15.a1 = $t$19;
          $i$15.w1.data = $t$19;
        }
      }
    }, i: false, f: null, g: 0, z: $input$3.picked };
    Rt$forKeyed($i$1.c0, $t$4, $t$6, $made$7, [$input$3.picked]);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomRowMount$t117 = Rt$template("<ul>");
const DomRowMount$k117 = { m: ($v$20, $cx$21) => {
  const $r$22 = DomRowMount$t117();
  const $c$23 = Rt$slot($r$22, null, $cx$21);
  const $i$24 = { s: $r$22, q: null, e: $r$22, c0: $c$23, g0_0: NaN, g0_1: NaN };
  DomRowMount$p117($i$24, $v$20);
  return $i$24;
}, p: DomRowMount$p117, l: true };
const DomRowMount$Msg$$order = { Pick: 0, Typed: 1 };
const DomRowMount$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DomRowMount$Msg$$order[$x.$] < DomRowMount$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Pick":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return String$compare($x.b, $y.b);
  }
};
const DomRowMount$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Pick":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a && $x.b === $y.b;
  }
};
const DomRowMount$after = (model$1) => ({ t: DomRowMount$k59, v: [model$1] });
const DomRowMount$before = (model$1) => ({ t: DomRowMount$k91, v: [model$1] });
const DomRowMount$toggled = (model$1) => ({ t: DomRowMount$k117, v: [model$1] });
export { DomRowMount$Msg$$compare, DomRowMount$Msg$$eq, DomRowMount$after, DomRowMount$before, DomRowMount$toggled };
//# sourceMappingURL=DomRowMount.mjs.map
