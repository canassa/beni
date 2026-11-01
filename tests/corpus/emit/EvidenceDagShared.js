import { deep as _derived$deep } from "./_core/_derived.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const EvidenceDagShared$eq$prim = ($x, $y) => $x === $y;
const EvidenceDagShared$eq$t2 = ($m$0, $m$1, $x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(EvidenceDagShared$eq$t2$$steps($m$0, $m$1, $x, $y), $d);
  }
  return $m$0($x.a, $y.a, $d + 1) && $m$1($x.b, $y.b, $d + 1);
};
function* EvidenceDagShared$eq$t2$$steps($m$0, $m$1, $x, $y) {
  let $e;
  $e = $m$0($x.a, $y.a, 2**30);
  if (typeof $e === "object") {
    $e = yield $e;
  }
  if (!$e) {
    return false;
  }
  return $m$1($x.b, $y.b, 2**30);
}
const EvidenceDagShared$w1 = (x$1) => ({ a: x$1, b: x$1 });
const EvidenceDagShared$w2 = (x$1) => EvidenceDagShared$w1(EvidenceDagShared$w1(x$1));
const EvidenceDagShared$w3 = (x$1) => EvidenceDagShared$w2(EvidenceDagShared$w2(x$1));
const EvidenceDagShared$w4 = (x$1) => EvidenceDagShared$w3(EvidenceDagShared$w3(x$1));
const EvidenceDagShared$main = (() => {
  const $t$4 = ($p$1, $p$2, $p$3) => EvidenceDagShared$eq$t2(EvidenceDagShared$eq$prim, EvidenceDagShared$eq$prim, $p$1, $p$2, $p$3);
  const $t$8 = ($p$5, $p$6, $p$7) => EvidenceDagShared$eq$t2($t$4, $t$4, $p$5, $p$6, $p$7);
  const $t$12 = ($p$9, $p$10, $p$11) => EvidenceDagShared$eq$t2($t$8, $t$8, $p$9, $p$10, $p$11);
  const $t$16 = ($p$13, $p$14, $p$15) => EvidenceDagShared$eq$t2($t$12, $t$12, $p$13, $p$14, $p$15);
  const $t$20 = ($p$17, $p$18, $p$19) => EvidenceDagShared$eq$t2($t$16, $t$16, $p$17, $p$18, $p$19);
  const $t$24 = ($p$21, $p$22, $p$23) => EvidenceDagShared$eq$t2($t$20, $t$20, $p$21, $p$22, $p$23);
  const $t$28 = ($p$25, $p$26, $p$27) => EvidenceDagShared$eq$t2($t$24, $t$24, $p$25, $p$26, $p$27);
  return Node$printLines([EvidenceDagShared$eq$t2($t$28, $t$28, EvidenceDagShared$w4(1), EvidenceDagShared$w4(2)) ? "T" : "F"]);
})();
export { EvidenceDagShared$main };
//# sourceMappingURL=EvidenceDagShared.mjs.map
