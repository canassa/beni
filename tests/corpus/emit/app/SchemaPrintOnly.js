import { Schema$compiledFail, Schema$pathAt, Schema$compiledPrint, Schema$defaultOptions } from "./_core/Schema.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const SchemaPrintOnly$Shape$$write = (c, d, p, k, n, v) => {
  switch (v.$) {
    case "Circle":
      {
        const $a$1 = v.a;
        if (d >= c.max) {
          return Schema$compiledFail(c, p, k, n, 5, "the depth limit is reached", $a$1, false);
        }
        const $before$2 = c.issues.length;
        const $deep$3 = d + 1 >= c.max;
        let $s$4;
        const $x$5 = $a$1.radius;
        if ($deep$3) {
          $s$4 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "radius", "radius", 5, "the depth limit is reached", $x$5, false);
        } else {
          if (!globalThis.Number.isFinite($x$5)) {
            $s$4 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "radius", "radius", 10, "JSON has no number for NaN or an infinity", $x$5, true);
          } else {
            $s$4 = $x$5;
          }
        }
        if ($s$4 === c.fail && !c.all) {
          return c.fail;
        }
        if (c.issues.length > $before$2) {
          return c.fail;
        }
        const $o$6 = {};
        $o$6["type"] = "circle";
        $o$6["radius"] = $s$4;
        return $o$6;
      }
    case "Square":
      {
        const $a$7 = v.a;
        if (d >= c.max) {
          return Schema$compiledFail(c, p, k, n, 5, "the depth limit is reached", $a$7, false);
        }
        const $before$8 = c.issues.length;
        const $deep$9 = d + 1 >= c.max;
        let $s$10;
        const $x$11 = $a$7.side;
        if ($deep$9) {
          $s$10 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "side", "side", 5, "the depth limit is reached", $x$11, false);
        } else {
          if (!globalThis.Number.isSafeInteger($x$11)) {
            $s$10 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "side", "side", 4, "expected a safe integer", $x$11, false);
          } else {
            $s$10 = $x$11;
          }
        }
        if ($s$10 === c.fail && !c.all) {
          return c.fail;
        }
        if (c.issues.length > $before$8) {
          return c.fail;
        }
        const $o$12 = {};
        $o$12["type"] = "square";
        $o$12["side"] = $s$10;
        return $o$12;
      }
    default:
      {
        const $o$13 = {};
        $o$13["type"] = "dot";
        return $o$13;
      }
  }
};
const SchemaPrintOnly$Shape$$printWith = ($o, $t) => Schema$compiledPrint($o, [], SchemaPrintOnly$Shape$$write, $t);
const SchemaPrintOnly$Shape$$print = ($t) => SchemaPrintOnly$Shape$$printWith(Schema$defaultOptions, $t);
const SchemaPrintOnly$main = (() => {
  const $t$14 = SchemaPrintOnly$Shape$$print({ $: "Square", a: { side: 2 } });
  let $t$15;
  if ($t$14.$ === "Ok") {
    const text$1 = $t$14.a;
    $t$15 = text$1;
  } else {
    $t$15 = "failed";
  }
  return Node$printLines([$t$15]);
})();
export { SchemaPrintOnly$main };
//# sourceMappingURL=SchemaPrintOnly.mjs.map
