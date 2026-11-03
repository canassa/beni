import { Rt$text, Rt$escapeAttr, Rt$escape, Rt$list } from "./_platform/Rt.mjs";
const MarkupSsr$k3 = { t: "<p class=\"lead\">Hello &amp; welcome</p>" };
const MarkupSsr$k21 = ["<p title=\"", "\">Hi ", ", ", " new<br>", "</p>"];
const MarkupSsr$k33 = ["<li>", "</li>"];
const MarkupSsr$k35 = ["<ul>", "</ul>"];
const MarkupSsr$static = MarkupSsr$k3;
const MarkupSsr$greet = (user$1) => {
  const $t$1 = user$1.name;
  const $t$2 = user$1.name;
  const $t$3 = user$1.count;
  const $t$4 = Rt$text("!");
  return { t: MarkupSsr$k21[0] + Rt$escapeAttr($t$1) + MarkupSsr$k21[1] + Rt$escape($t$2) + MarkupSsr$k21[2] + $t$3 + MarkupSsr$k21[3] + $t$4.t + MarkupSsr$k21[4] };
};
const MarkupSsr$list = (items$1) => ({ t: MarkupSsr$k35[0] + Rt$list(items$1, ($item$1) => ({ t: MarkupSsr$k33[0] + Rt$escape($item$1) + MarkupSsr$k33[1] }), null) + MarkupSsr$k35[1] });
export { MarkupSsr$static, MarkupSsr$greet, MarkupSsr$list };
//# sourceMappingURL=MarkupSsr.mjs.map
