import { Rt$templateOf, Rt$empty, Rt$childHtml, Rt$restate, Rt$template, Rt$slot } from "./_platform/Rt.mjs";
import { Card$view } from "./Card.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomComponents$t14n4 = Rt$templateOf("Welcome, <b> </b>!", 4);
const DomComponents$k14n4 = { m: ($v$8, $cx$9) => {
  const $r$10 = DomComponents$t14n4();
  const $w$11 = $r$10.firstChild;
  const $w$12 = $w$11.nextSibling;
  const $w$13 = $w$12.firstChild;
  const $w$14 = $w$12.nextSibling;
  $w$13.data = $v$8[0];
  return { s: $w$11, q: Rt$empty, e: $w$14, w2: $w$13, a0: $v$8[0] };
}, p: ($i$15, $v$16) => {
  if ($v$16[0] !== $i$15.a0) {
    $i$15.a0 = $v$16[0];
    $i$15.w2.data = $v$16[0];
  }
} };
const DomComponents$t14n6 = Rt$template("no values");
const DomComponents$k14n6 = { m: ($v$19, $cx$20) => {
  const $r$21 = DomComponents$t14n6();
  return { s: $r$21, q: Rt$empty, e: $r$21 };
}, p: ($i$22, $v$23) => {
} };
const DomComponents$b14n6 = { t: DomComponents$k14n6, v: null };
const DomComponents$p14 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $input$4 = $v$2.b;
  if ($input$3.title !== $i$1.g0_0 || $input$3.name !== $i$1.g0_1 || $input$4 !== $i$1.g0_2) {
    $i$1.g0_0 = $input$3.title;
    $i$1.g0_1 = $input$3.name;
    $i$1.g0_2 = $input$4;
    const $t$5 = $input$3.title;
    const $t$6 = $input$3.name;
    const $made$7 = { t: DomComponents$k14n4, v: [$t$6] };
    if ($t$5 !== $i$1.a0_0 || true) {
      $i$1.a0_0 = $t$5;
      Rt$childHtml($i$1.c0, Card$view($input$4, { children: $made$7, title: $t$5 }));
    } else {
      Rt$restate($i$1.c0);
    }
  } else {
    Rt$restate($i$1.c0);
  }
  const $x$17 = $input$4;
  if ($x$17 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$17;
    const $made$18 = DomComponents$b14n6;
    if (true) {
      Rt$childHtml($i$1.c1, Card$view($input$4, { children: $made$18, title: "static" }));
    } else {
      Rt$restate($i$1.c1);
    }
  } else {
    Rt$restate($i$1.c1);
  }
  $i$1.$l = $i$1.c0.l || $i$1.c1.l;
};
const DomComponents$t14 = Rt$template("<main><!><!>");
const DomComponents$k14 = { m: ($v$24, $cx$25) => {
  const $r$26 = DomComponents$t14();
  const $w$27 = $r$26.firstChild;
  const $w$28 = $w$27.nextSibling;
  const $c$29 = Rt$slot($r$26, $w$27, $cx$25);
  const $c$30 = Rt$slot($r$26, $w$28, $cx$25);
  const $i$31 = { s: $r$26, q: Rt$empty, e: $r$26, c0: $c$29, c1: $c$30, a0_0: undefined, a0c: undefined, a1c: undefined, g0_0: NaN, g0_1: NaN, g0_2: NaN, g1_0: NaN };
  DomComponents$p14($i$31, $v$24);
  return $i$31;
}, p: DomComponents$p14, l: true };
const DomComponents$page$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{name=core:String.String,title=core:String.String}" + "," + "core:String.String" + ")", a: undefined, b: undefined };
const DomComponents$page = ($m$0, r$1) => ({ t: DomComponents$k14, v: { ...DomComponents$page$$packet$1, a: r$1, b: $m$0 } });
export { DomComponents$page };
//# sourceMappingURL=DomComponents.mjs.map
