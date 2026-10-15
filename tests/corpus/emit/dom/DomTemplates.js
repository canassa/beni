import { Rt$template, Rt$insertText, Rt$attr } from "./_platform/Rt.mjs";
const DomTemplates$t3 = Rt$template("<div class=\"a b\"id=x><span>hi</span><br><p>there <b>you &amp; me");
const DomTemplates$k3 = { m: ($v$1, $cx$2) => {
  const $r$3 = DomTemplates$t3();
  return { s: $r$3, q: null, e: $r$3 };
}, p: ($i$4, $v$5) => {
} };
const DomTemplates$b3 = { t: DomTemplates$k3, v: null };
const DomTemplates$p19 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.name;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.x0.data = $x$4;
  }
  const $x$5 = $input$3.count;
  if ($x$5 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$5;
    $i$1.x1.data = $x$5;
  }
  const $x$6 = $input$3.more;
  if ($x$6 !== $i$1.g2_0) {
    $i$1.g2_0 = $x$6;
    $i$1.x2.data = $x$6;
  }
};
const DomTemplates$t19 = Rt$template("<p>Hello <!>, you have <!> items and <!> more.");
const DomTemplates$k19 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomTemplates$t19();
  const $w$10 = $r$9.firstChild.nextSibling;
  const $w$11 = $w$10.nextSibling.nextSibling;
  const $w$12 = $w$11.nextSibling.nextSibling;
  const $x$13 = Rt$insertText($r$9, $w$10, "");
  const $x$14 = Rt$insertText($r$9, $w$11, "");
  const $x$15 = Rt$insertText($r$9, $w$12, "");
  const $i$16 = { s: $r$9, q: null, e: $r$9, x0: $x$13, x1: $x$14, x2: $x$15, g0_0: NaN, g1_0: NaN, g2_0: NaN };
  DomTemplates$p19($i$16, $v$7);
  return $i$16;
}, p: DomTemplates$p19 };
const DomTemplates$p32 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.id;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w2.data = $x$4;
  }
  const $x$5 = $input$3.label;
  if ($x$5 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$5;
    $i$1.w5.data = $x$5;
  }
};
const DomTemplates$t32 = Rt$template("<tr><td class=col-md-1> </td><td class=col-md-4><a> ");
const DomTemplates$k32 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomTemplates$t32();
  const $w$9 = $r$8.firstChild;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$9.nextSibling;
  const $w$12 = $w$11.firstChild;
  const $w$13 = $w$12.firstChild;
  const $i$14 = { s: $r$8, q: null, e: $r$8, w2: $w$10, w5: $w$13, g0_0: NaN, g1_0: NaN };
  DomTemplates$p32($i$14, $v$6);
  return $i$14;
}, p: DomTemplates$p32 };
const DomTemplates$p51 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.id;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("id", $x$4);
  }
  const $x$5 = $input$3.title;
  if ($x$5 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$5;
    $i$1.w0.setAttribute("title", $x$5);
  }
  const $x$6 = $input$3.off;
  if ($x$6 !== $i$1.g2_0) {
    $i$1.g2_0 = $x$6;
    Rt$attr($i$1.w0, "hidden", $x$6 ? "" : null);
  }
  const $x$7 = $input$3.tab;
  if ($x$7 !== $i$1.g3_0) {
    $i$1.g3_0 = $x$7;
    $i$1.w0.setAttribute("tabindex", $x$7);
  }
};
const DomTemplates$t51 = Rt$template("<div aria-label=static><input disabled type=text>");
const DomTemplates$k51 = { m: ($v$8, $cx$9) => {
  const $r$10 = DomTemplates$t51();
  const $i$11 = { s: $r$10, q: null, e: $r$10, w0: $r$10, g0_0: NaN, g1_0: NaN, g2_0: NaN, g3_0: NaN };
  DomTemplates$p51($i$11, $v$8);
  return $i$11;
}, p: DomTemplates$p51 };
const DomTemplates$t55 = Rt$template("<!>");
const DomTemplates$k55 = { m: ($v$1, $cx$2) => {
  const $r$3 = DomTemplates$t55();
  return { s: $r$3, q: null, e: $r$3 };
}, p: ($i$4, $v$5) => {
} };
const DomTemplates$b55 = { t: DomTemplates$k55, v: null };
const DomTemplates$static = DomTemplates$b3;
const DomTemplates$text = (r$1) => ({ t: DomTemplates$k19, v: [r$1] });
const DomTemplates$only = (row$1) => ({ t: DomTemplates$k32, v: [row$1] });
const DomTemplates$attributes = (r$1) => ({ t: DomTemplates$k51, v: [r$1] });
const DomTemplates$nothing = DomTemplates$b55;
export { DomTemplates$static, DomTemplates$text, DomTemplates$only, DomTemplates$attributes, DomTemplates$nothing };
//# sourceMappingURL=DomTemplates.mjs.map
