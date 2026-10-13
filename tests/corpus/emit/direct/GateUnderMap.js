import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$slot, Direct$unset, Direct$map, Direct$childHtml, Direct$restate, Direct$text, Direct$template, Direct$on, Direct$wrong, Direct$same, Direct$verifySlot, Direct$verify } from "./_platform/Direct.mjs";
const GateUnderMap$p39 = (i$25, v$26) => {
  const $in$27 = v$26[0];
  const x$28 = $in$27.b;
  if (x$28 !== i$25.g0_0) {
    i$25.g0_0 = x$28;
    const $t$29 = $in$27.b;
    if ($t$29 !== i$25.a0_0) {
      i$25.a0_0 = $t$29;
      Direct$childHtml(i$25.c0, GateUnderMap$chip($t$29));
    } else {
      Direct$restate(i$25.c0);
    }
  } else {
    Direct$restate(i$25.c0);
  }
  const x$30 = $in$27.c;
  if (x$30 !== i$25.g1_0) {
    i$25.g1_0 = x$30;
    const $t$31 = Direct$text($in$27.c);
    Direct$childHtml(i$25.c1, $t$31);
  } else {
    Direct$restate(i$25.c1);
  }
  i$25.l = i$25.c0.l || i$25.c1.l;
};
const GateUnderMap$t39 = Direct$template("<div><!><!>", 0);
const GateUnderMap$k39 = { m: (v$32, cx$33) => {
  const r$34 = GateUnderMap$t39();
  const w$35 = r$34.firstChild;
  const w$36 = w$35.nextSibling;
  const c$37 = Direct$slot(r$34, w$35, cx$33);
  const c$38 = Direct$slot(r$34, w$36, cx$33);
  const i$39 = { s: r$34, q: null, e: r$34, c0: c$37, c1: c$38, a0_0: undefined, g0_0: NaN, g1_0: NaN };
  GateUnderMap$p39(i$39, v$32);
  return i$39;
}, p: GateUnderMap$p39, l: true };
const GateUnderMap$p16 = (i$51, v$52) => {
  const $in$53 = v$52[0];
  const x$54 = $in$53;
  if (x$54 !== i$51.g0_0) {
    i$51.g0_0 = x$54;
    i$51.w2.data = x$54;
    i$51.w4.data = x$54;
    i$51.w6.data = x$54;
    i$51.w8.data = x$54;
  }
};
const GateUnderMap$t16 = Direct$template("<span class=\"chip chip-large chip-outlined chip-with-a-long-class-list\"><b> </b><i> </i><u> </u><em> ", 0);
const GateUnderMap$k16 = { m: (v$55, cx$56) => {
  const r$57 = GateUnderMap$t16();
  const w$58 = r$57.firstChild;
  const w$59 = w$58.firstChild;
  const w$60 = w$58.nextSibling;
  const w$61 = w$60.firstChild;
  const w$62 = w$60.nextSibling;
  const w$63 = w$62.firstChild;
  const w$64 = w$62.nextSibling;
  const w$65 = w$64.firstChild;
  const i$66 = { s: r$57, q: null, e: r$57, w2: w$59, w4: w$61, w6: w$63, w8: w$65, g0_0: NaN };
  GateUnderMap$p16(i$66, v$55);
  return i$66;
}, p: GateUnderMap$p16 };
const GateUnderMap$chip = (s$1) => ({ t: GateUnderMap$k16, v: [s$1] });
const GateUnderMap$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { a: "a", b: "b", c: "c" };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><button>set</button><span class=\"chip chip-large chip-outlined chip-with-a-long-class-list\"><b> </b><i> </i><u> </u><em> ";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.nextSibling;
  const $w$9 = $w$8.firstChild;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$9.nextSibling;
  const $w$12 = $w$11.firstChild;
  const $w$13 = $w$11.nextSibling;
  const $w$14 = $w$13.firstChild;
  const $w$15 = $w$13.nextSibling;
  const $w$16 = $w$15.firstChild;
  const $c$17 = Direct$slot($w$6, null, null);
  let $s$18 = Direct$unset;
  let $s$19 = Direct$unset;
  let $s$20 = Direct$unset;
  let $s$21 = Direct$unset;
  const $g$22 = () => {
    const $t$23 = $model$4.a;
    if ($t$23 !== $s$18) {
      $w$10.data = $t$23;
      $s$18 = $t$23;
    }
    if ($t$23 !== $s$19) {
      $w$12.data = $t$23;
      $s$19 = $t$23;
    }
    if ($t$23 !== $s$20) {
      $w$14.data = $t$23;
      $s$20 = $t$23;
    }
    if ($t$23 !== $s$21) {
      $w$16.data = $t$23;
      $s$21 = $t$23;
    }
  };
  const $g$24 = () => {
    const $t$40 = Direct$map({ t: GateUnderMap$k39, v: [$model$4] }, (msg$5) => msg$5);
    Direct$childHtml($c$17, $t$40);
  };
  const $hSet$42 = ($p$41) => {
    $model$4 = { ...$model$4, a: $p$41 };
    $g$22();
    $g$24();
  };
  const $hInner$44 = ($p$43) => {
    $model$4 = undefined;
    $g$24();
  };
  const $dispatch$47 = ($msg$48) => {
    if ($msg$48.$ === "Set") {
      $hSet$42($msg$48.a);
      return;
    }
    $hInner$44($msg$48.a);
  };
  $root$1.$$root = $dispatch$47;
  {
    const $l$46 = ($e$45) => {
      $hSet$42("x");
    };
    Direct$on($w$7, "click", $l$46);
  }
  $g$22();
  $g$24();
  $root$1.append($r$5);
  Direct$verify(() => {
    {
      const $t$49 = $model$4.a;
      if (!Direct$same($t$49, $s$18)) {
        Direct$wrong("the text hole at GateUnderMap.beni:26:12", $s$18, $t$49);
      }
      if ($w$10.data !== `${$t$49}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:26:12 in the document", $w$10.data, `${$t$49}`);
      }
      if (!Direct$same($t$49, $s$19)) {
        Direct$wrong("the text hole at GateUnderMap.beni:27:12", $s$19, $t$49);
      }
      if ($w$12.data !== `${$t$49}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:27:12 in the document", $w$12.data, `${$t$49}`);
      }
      if (!Direct$same($t$49, $s$20)) {
        Direct$wrong("the text hole at GateUnderMap.beni:28:12", $s$20, $t$49);
      }
      if ($w$14.data !== `${$t$49}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:28:12 in the document", $w$14.data, `${$t$49}`);
      }
      if (!Direct$same($t$49, $s$21)) {
        Direct$wrong("the text hole at GateUnderMap.beni:29:13", $s$21, $t$49);
      }
      if ($w$16.data !== `${$t$49}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:29:13 in the document", $w$16.data, `${$t$49}`);
      }
    }
    {
      const $t$50 = Direct$map({ t: GateUnderMap$k39, v: [$model$4] }, (msg$22) => msg$22);
      Direct$verifySlot($c$17, $t$50, 0, "the markup at GateUnderMap.beni:38:9");
    }
  });
});
export { GateUnderMap$main };
//# sourceMappingURL=GateUnderMap.mjs.map
