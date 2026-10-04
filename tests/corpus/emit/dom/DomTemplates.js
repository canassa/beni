import { Rt$template, Rt$insertText, Rt$attr } from "./_platform/Rt.mjs";
const DomTemplates$t3 = Rt$template("<div class=\"a b\"id=x><span>hi</span><br><p>there <b>you &amp; me", 0);
const DomTemplates$k3 = { m: (v$1, cx$2) => {
  const r$3 = DomTemplates$t3();
  return { s: r$3, q: null, e: r$3 };
}, p: (i$4, v$5) => {
} };
const DomTemplates$b3 = { t: DomTemplates$k3, v: null };
const DomTemplates$p19 = (i$6, v$7) => {
  const $in$8 = v$7[0];
  if ($in$8.name !== i$6.g0_0) {
    i$6.g0_0 = $in$8.name;
    const $t$9 = $in$8.name;
    if ($t$9 !== i$6.a0) {
      i$6.a0 = $t$9;
      i$6.x0.data = $t$9;
    }
  }
  if ($in$8.count !== i$6.g1_0) {
    i$6.g1_0 = $in$8.count;
    const $t$10 = $in$8.count;
    if ($t$10 !== i$6.a1) {
      i$6.a1 = $t$10;
      i$6.x1.data = $t$10;
    }
  }
  if ($in$8.more !== i$6.g2_0) {
    i$6.g2_0 = $in$8.more;
    const $t$11 = $in$8.more;
    if ($t$11 !== i$6.a2) {
      i$6.a2 = $t$11;
      i$6.x2.data = $t$11;
    }
  }
};
const DomTemplates$t19 = Rt$template("<p>Hello <!>, you have <!> items and <!> more.", 0);
const DomTemplates$k19 = { m: (v$12, cx$13) => {
  const r$14 = DomTemplates$t19();
  const w$15 = r$14.firstChild.nextSibling;
  const w$16 = w$15.nextSibling.nextSibling;
  const w$17 = w$16.nextSibling.nextSibling;
  const x$18 = Rt$insertText(r$14, w$15, "");
  const x$19 = Rt$insertText(r$14, w$16, "");
  const x$20 = Rt$insertText(r$14, w$17, "");
  const i$21 = { s: r$14, q: null, e: r$14, x0: x$18, x1: x$19, x2: x$20, a0: undefined, a1: undefined, a2: undefined, g0_0: undefined, g1_0: undefined, g2_0: undefined };
  DomTemplates$p19(i$21, v$12);
  return i$21;
}, p: DomTemplates$p19 };
const DomTemplates$p32 = (i$22, v$23) => {
  const $in$24 = v$23[0];
  if ($in$24.id !== i$22.g0_0) {
    i$22.g0_0 = $in$24.id;
    const $t$25 = $in$24.id;
    if ($t$25 !== i$22.a0) {
      i$22.a0 = $t$25;
      i$22.w2.data = $t$25;
    }
  }
  if ($in$24.label !== i$22.g1_0) {
    i$22.g1_0 = $in$24.label;
    const $t$26 = $in$24.label;
    if ($t$26 !== i$22.a1) {
      i$22.a1 = $t$26;
      i$22.w5.data = $t$26;
    }
  }
};
const DomTemplates$t32 = Rt$template("<tr><td class=col-md-1> </td><td class=col-md-4><a> ", 0);
const DomTemplates$k32 = { m: (v$27, cx$28) => {
  const r$29 = DomTemplates$t32();
  const w$30 = r$29.firstChild;
  const w$31 = w$30.firstChild;
  const w$32 = w$30.nextSibling;
  const w$33 = w$32.firstChild;
  const w$34 = w$33.firstChild;
  const i$35 = { s: r$29, q: null, e: r$29, w2: w$31, w5: w$34, a0: undefined, a1: undefined, g0_0: undefined, g1_0: undefined };
  DomTemplates$p32(i$35, v$27);
  return i$35;
}, p: DomTemplates$p32 };
const DomTemplates$p51 = (i$36, v$37) => {
  const $in$38 = v$37[0];
  if ($in$38.id !== i$36.g0_0) {
    i$36.g0_0 = $in$38.id;
    const $t$39 = $in$38.id;
    if ($t$39 !== i$36.a0) {
      i$36.w0.setAttribute("id", $t$39);
      i$36.a0 = $t$39;
    }
  }
  if ($in$38.title !== i$36.g1_0) {
    i$36.g1_0 = $in$38.title;
    const $t$40 = $in$38.title;
    if ($t$40 !== i$36.a1) {
      i$36.w0.setAttribute("title", $t$40);
      i$36.a1 = $t$40;
    }
  }
  if ($in$38.off !== i$36.g2_0) {
    i$36.g2_0 = $in$38.off;
    const $t$41 = $in$38.off;
    if ($t$41 !== i$36.a2) {
      Rt$attr(i$36.w0, "hidden", $t$41 ? "" : null);
      i$36.a2 = $t$41;
    }
  }
  if ($in$38.tab !== i$36.g3_0) {
    i$36.g3_0 = $in$38.tab;
    const $t$42 = $in$38.tab;
    if ($t$42 !== i$36.a3) {
      i$36.w0.setAttribute("tabindex", $t$42);
      i$36.a3 = $t$42;
    }
  }
};
const DomTemplates$t51 = Rt$template("<div aria-label=static><input disabled type=text>", 0);
const DomTemplates$k51 = { m: (v$43, cx$44) => {
  const r$45 = DomTemplates$t51();
  const i$46 = { s: r$45, q: null, e: r$45, w0: r$45, a0: undefined, a1: undefined, a2: undefined, a3: undefined, g0_0: undefined, g1_0: undefined, g2_0: undefined, g3_0: undefined };
  DomTemplates$p51(i$46, v$43);
  return i$46;
}, p: DomTemplates$p51 };
const DomTemplates$t55 = Rt$template("<!>", 0);
const DomTemplates$k55 = { m: (v$47, cx$48) => {
  const r$49 = DomTemplates$t55();
  return { s: r$49, q: null, e: r$49 };
}, p: (i$50, v$51) => {
} };
const DomTemplates$b55 = { t: DomTemplates$k55, v: null };
const DomTemplates$static = DomTemplates$b3;
const DomTemplates$text = (r$1) => ({ t: DomTemplates$k19, v: [r$1] });
const DomTemplates$only = (row$1) => ({ t: DomTemplates$k32, v: [row$1] });
const DomTemplates$attributes = (r$1) => ({ t: DomTemplates$k51, v: [r$1] });
const DomTemplates$nothing = DomTemplates$b55;
export { DomTemplates$static, DomTemplates$text, DomTemplates$only, DomTemplates$attributes, DomTemplates$nothing };
//# sourceMappingURL=DomTemplates.mjs.map
