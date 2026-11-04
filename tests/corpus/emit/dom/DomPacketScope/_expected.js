import { Keep$keep } from "./_platform/Keep.mjs";
import { Rt$childHtml, Rt$restate, Rt$template, Rt$empty, Rt$slot } from "./_platform/_browser/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomPacketScope$p15 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $input$4 = $v$2.b;
  {
    const $t$5 = Keep$keep("platform:Html.Html(" + $input$4 + ")", $input$3);
    Rt$childHtml($i$1.c0, $t$5);
  }
  $i$1.$l = $i$1.c0.l;
};
const DomPacketScope$t15 = Rt$template("<section>");
const DomPacketScope$k15 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomPacketScope$t15();
  const $c$9 = Rt$slot($r$8, Rt$empty, $cx$7);
  const $i$10 = { s: $r$8, q: Rt$empty, e: $r$8, c0: $c$9 };
  DomPacketScope$p15($i$10, $v$6);
  return $i$10;
}, p: DomPacketScope$p15, l: true };
const DomPacketScope$t17 = Rt$template("<b>kept");
const DomPacketScope$k17 = { m: ($v$11, $cx$12) => {
  const $r$13 = DomPacketScope$t17();
  return { s: $r$13, q: Rt$empty, e: $r$13 };
}, p: ($i$14, $v$15) => {
} };
const DomPacketScope$b17 = { t: DomPacketScope$k17, v: null };
const DomPacketScope$local = (() => {
  function render$1($l3$0, value$2) {
    return { t: DomPacketScope$k15, v: { a: value$2, b: $l3$0, [Js$Any$pack.$packet.key]: "(" + ("platform:Html.Html(" + $l3$0 + ")") + "," + "core:String.String" + ")" } };
  }
  return render$1("core:Basics.Int", DomPacketScope$b17);
})();
export { DomPacketScope$local };
//# sourceMappingURL=DomPacketScope.mjs.map
