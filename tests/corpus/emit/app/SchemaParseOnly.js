import { Schema$conversion, Schema$issue, Schema$compiledFail, Schema$pathAt, Schema$compiledForward, Schema$compiledParse, Schema$defaultOptions } from "./_core/Schema.mjs";
import { String$toInt, String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const SchemaParseOnly$decimalInt = Schema$conversion((s$1) => {
  const $t$1 = String$toInt(s$1);
  if ($t$1.$ === "Just") {
    const n$2 = $t$1.a;
    return { $: "Ok", a: n$2 };
  } else {
    return { $: "Err", a: [Schema$issue("not a decimal integer")] };
  }
}, (n$3) => ({ $: "Ok", a: String$fromInt(n$3) }));
const SchemaParseOnly$User$$via$0 = SchemaParseOnly$decimalInt;
const SchemaParseOnly$User$$read = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "user-name" && $key$2 !== "age" && $key$2 !== "scores") {
        Schema$compiledFail(c, $here, $key$2, $key$2, 2, "unexpected key \"" + $key$2 + "\"", v[$key$2], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  let $f$5;
  const $x$6 = v["user-name"];
  if ($x$6 !== undefined) {
    if ($deep$4) {
      $f$5 = Schema$compiledFail(c, $here, "user-name", "name", 5, "the depth limit is reached", $x$6, false);
    } else {
      if (typeof $x$6 !== "string") {
        $f$5 = Schema$compiledFail(c, $here, "user-name", "name", 0, "expected a string", $x$6, false);
      } else {
        $f$5 = $x$6;
      }
    }
  } else {
    $f$5 = Schema$compiledFail(c, $here, "user-name", "name", 1, "missing key \"user-name\"", v, false);
  }
  if ($f$5 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$7;
  const $x$8 = v["age"];
  if ($x$8 !== undefined) {
    if ($deep$4) {
      $f$7 = Schema$compiledFail(c, $here, "age", "age", 5, "the depth limit is reached", $x$8, false);
    } else {
      let $b$9;
      if (typeof $x$8 !== "string") {
        $b$9 = Schema$compiledFail(c, $here, "age", "age", 0, "expected a string", $x$8, false);
      } else {
        $b$9 = $x$8;
      }
      $f$7 = $b$9 === c.fail ? c.fail : Schema$compiledForward(c, $here, "age", "age", SchemaParseOnly$User$$via$0, $b$9);
    }
  } else {
    $f$7 = Schema$compiledFail(c, $here, "age", "age", 1, "missing key \"age\"", v, false);
  }
  if ($f$7 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$10;
  const $x$11 = v["scores"];
  if ($x$11 !== undefined) {
    if ($deep$4) {
      $f$10 = Schema$compiledFail(c, $here, "scores", "scores", 5, "the depth limit is reached", $x$11, false);
    } else {
      $f$10 = SchemaParseOnly$User$$read$4(c, d + 1, $here, "scores", "scores", $x$11);
    }
  } else {
    $f$10 = Schema$compiledFail(c, $here, "scores", "scores", 1, "missing key \"scores\"", v, false);
  }
  if ($f$10 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { age: $f$7, name: $f$5, scores: $f$10 };
};
const SchemaParseOnly$User$$read$4 = (c, d, p, k, n, v) => {
  if (!globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an array", v, false);
  }
  const $before$12 = c.issues.length;
  const $len$13 = v.length;
  const $deep$14 = d >= c.max;
  let $i$16 = 0;
  while (!($i$16 >= $len$13)) {
    const $x$17 = v[$i$16];
    let $y$18;
    if ($deep$14) {
      $y$18 = Schema$compiledFail(c, Schema$pathAt(p, k, n), $i$16, $i$16, 5, "the depth limit is reached", $x$17, false);
    } else {
      if (typeof $x$17 !== "number") {
        $y$18 = Schema$compiledFail(c, Schema$pathAt(p, k, n), $i$16, $i$16, 0, "expected a number", $x$17, false);
      } else {
        if (!globalThis.Number.isSafeInteger($x$17)) {
          $y$18 = Schema$compiledFail(c, Schema$pathAt(p, k, n), $i$16, $i$16, 4, "expected a safe integer", $x$17, false);
        } else {
          $y$18 = $x$17;
        }
      }
    }
    if ($y$18 === c.fail) {
      if (!c.all) {
        return c.fail;
      }
    }
    $i$16 = $i$16 + 1;
  }
  if (c.issues.length > $before$12) {
    return c.fail;
  }
  return v;
};
const SchemaParseOnly$User$$parseWith = ($o, $t) => Schema$compiledParse($o, null, SchemaParseOnly$User$$read, $t);
const SchemaParseOnly$User$$parse = ($t) => SchemaParseOnly$User$$parseWith(Schema$defaultOptions(), $t);
const SchemaParseOnly$main = (() => {
  const $t$1 = SchemaParseOnly$User$$parse("{\"user-name\":\"a\",\"age\":\"3\",\"scores\":[1]}");
  let $t$2;
  if ($t$1.$ === "Ok") {
    const u$1 = $t$1.a;
    $t$2 = u$1.name;
  } else {
    $t$2 = "failed";
  }
  return Node$printLines([$t$2]);
})();
export { SchemaParseOnly$main };
//# sourceMappingURL=SchemaParseOnly.mjs.map
