import { Rt$template } from "./_platform/Rt.mjs";
const DomIframeSrcdoc$t3 = Rt$template("<iframe sandbox srcdoc=\"&lt;p title=&quot;a &amp; b&quot;>x&lt;/p>&lt;script>alert(1)&lt;/script>&lt;/iframe>\">");
const DomIframeSrcdoc$k3 = { m: ($v$1, $cx$2) => {
  const $r$3 = DomIframeSrcdoc$t3();
  return { s: $r$3, q: null, e: $r$3 };
}, p: ($i$4, $v$5) => {
} };
const DomIframeSrcdoc$b3 = { t: DomIframeSrcdoc$k3, v: null };
const DomIframeSrcdoc$p11 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("srcdoc", $x$4);
  }
};
const DomIframeSrcdoc$t11 = Rt$template("<iframe sandbox>");
const DomIframeSrcdoc$k11 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomIframeSrcdoc$t11();
  const $i$8 = { s: $r$7, q: null, e: $r$7, w0: $r$7, g0_0: NaN };
  DomIframeSrcdoc$p11($i$8, $v$5);
  return $i$8;
}, p: DomIframeSrcdoc$p11 };
const DomIframeSrcdoc$constant = DomIframeSrcdoc$b3;
const DomIframeSrcdoc$held = (page$1) => ({ t: DomIframeSrcdoc$k11, v: [page$1] });
export { DomIframeSrcdoc$constant, DomIframeSrcdoc$held };
//# sourceMappingURL=DomIframeSrcdoc.mjs.map
