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
  const $before$2 = c.issues.length;
  if (c.reject) {
    for (const $key$3 of globalThis.Object.keys(v)) {
      if ($key$3 !== "user-name" && $key$3 !== "age" && $key$3 !== "scores") {
        Schema$compiledFail(c, $here, $key$3, $key$3, 2, "unexpected key \"" + $key$3 + "\"", v[$key$3], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$5 = d >= c.max;
  let $f$6;
  const $x$7 = v["user-name"];
  if ($x$7 !== undefined) {
    if ($deep$5) {
      $f$6 = Schema$compiledFail(c, $here, "user-name", "name", 5, "the depth limit is reached", $x$7, false);
    } else {
      if (typeof $x$7 !== "string") {
        $f$6 = Schema$compiledFail(c, $here, "user-name", "name", 0, "expected a string", $x$7, false);
      } else {
        $f$6 = $x$7;
      }
    }
  } else {
    $f$6 = Schema$compiledFail(c, $here, "user-name", "name", 1, "missing key \"user-name\"", v, false);
  }
  if ($f$6 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$8;
  const $x$9 = v["age"];
  if ($x$9 !== undefined) {
    if ($deep$5) {
      $f$8 = Schema$compiledFail(c, $here, "age", "age", 5, "the depth limit is reached", $x$9, false);
    } else {
      let $b$10;
      if (typeof $x$9 !== "string") {
        $b$10 = Schema$compiledFail(c, $here, "age", "age", 0, "expected a string", $x$9, false);
      } else {
        $b$10 = $x$9;
      }
      $f$8 = $b$10 === c.fail ? c.fail : Schema$compiledForward(c, $here, "age", "age", SchemaParseOnly$User$$via$0, $b$10);
    }
  } else {
    $f$8 = Schema$compiledFail(c, $here, "age", "age", 1, "missing key \"age\"", v, false);
  }
  if ($f$8 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$11;
  const $x$12 = v["scores"];
  if ($x$12 !== undefined) {
    if ($deep$5) {
      $f$11 = Schema$compiledFail(c, $here, "scores", "scores", 5, "the depth limit is reached", $x$12, false);
    } else {
      $f$11 = SchemaParseOnly$User$$read$4(c, d + 1, $here, "scores", "scores", $x$12);
    }
  } else {
    $f$11 = Schema$compiledFail(c, $here, "scores", "scores", 1, "missing key \"scores\"", v, false);
  }
  if ($f$11 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$2) {
    return c.fail;
  }
  return { age: $f$8, name: $f$6, scores: $f$11 };
};
const SchemaParseOnly$User$$read$4 = (c, d, p, k, n, v) => {
  if (!globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an array", v, false);
  }
  const $before$13 = c.issues.length;
  const $len$14 = v.length;
  const $deep$15 = d >= c.max;
  let $i$17 = 0;
  while (!($i$17 >= $len$14)) {
    const $x$18 = v[$i$17];
    let $y$19;
    if ($deep$15) {
      $y$19 = Schema$compiledFail(c, Schema$pathAt(p, k, n), $i$17, $i$17, 5, "the depth limit is reached", $x$18, false);
    } else {
      if (typeof $x$18 !== "number") {
        $y$19 = Schema$compiledFail(c, Schema$pathAt(p, k, n), $i$17, $i$17, 0, "expected a number", $x$18, false);
      } else {
        if (!globalThis.Number.isSafeInteger($x$18)) {
          $y$19 = Schema$compiledFail(c, Schema$pathAt(p, k, n), $i$17, $i$17, 4, "expected a safe integer", $x$18, false);
        } else {
          $y$19 = $x$18;
        }
      }
    }
    if ($y$19 === c.fail) {
      if (!c.all) {
        return c.fail;
      }
    }
    $i$17 = $i$17 + 1;
  }
  if (c.issues.length > $before$13) {
    return c.fail;
  }
  return v;
};
const SchemaParseOnly$User$$parseWith = ($o, $t) => Schema$compiledParse($o, [], SchemaParseOnly$User$$read, $t);
const SchemaParseOnly$User$$parse = ($t) => SchemaParseOnly$User$$parseWith(Schema$defaultOptions, $t);
const SchemaParseOnly$main = (() => {
  const $t$20 = SchemaParseOnly$User$$parse("{\"user-name\":\"a\",\"age\":\"3\",\"scores\":[1]}");
  let $t$21;
  if ($t$20.$ === "Ok") {
    const u$1 = $t$20.a;
    $t$21 = u$1.name;
  } else {
    $t$21 = "failed";
  }
  return Node$printLines([$t$21]);
})();
export { SchemaParseOnly$main };
//# sourceMappingURL=SchemaParseOnly.mjs.map
