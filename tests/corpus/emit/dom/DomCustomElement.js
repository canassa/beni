import { Rt$templateOf, Rt$empty } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomCustomElement$p7 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("title", $x$4);
  }
};
const DomCustomElement$t7 = Rt$templateOf("<my-widget><x-a-b>hi", 1);
const DomCustomElement$k7 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomCustomElement$t7();
  const $i$8 = { s: $r$7, q: Rt$empty, e: $r$7, w0: $r$7, g0_0: NaN };
  DomCustomElement$p7($i$8, $v$5);
  return $i$8;
}, p: DomCustomElement$p7 };
const DomCustomElement$view$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + ")", a: undefined };
const DomCustomElement$view = (s$1) => ({ t: DomCustomElement$k7, v: { ...DomCustomElement$view$$packet$1, a: s$1 } });
export { DomCustomElement$view };
//# sourceMappingURL=DomCustomElement.mjs.map
