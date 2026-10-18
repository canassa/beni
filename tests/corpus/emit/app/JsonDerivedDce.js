import { Schema$compiledFail, Schema$pathAt, Schema$compiledParse, Schema$defaultOptions } from "./_core/Schema.mjs";
import { Basics$append } from "./_core/Basics.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const JsonDerivedDce$$codec1$$read = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $before$1 = c.issues.length;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "rank" && $key$2 !== "title") {
        Schema$compiledFail(c, Schema$pathAt(p, k, n), $key$2, $key$2, 2, "unexpected key \"" + $key$2 + "\"", v[$key$2], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  let $f$5;
  const $x$6 = v["rank"];
  if ($x$6 !== undefined) {
    if ($deep$4) {
      $f$5 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "rank", "rank", 5, "the depth limit is reached", $x$6, false);
    } else {
      if (typeof $x$6 !== "number") {
        $f$5 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "rank", "rank", 0, "expected a number", $x$6, false);
      } else {
        if (!globalThis.Number.isSafeInteger($x$6)) {
          $f$5 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "rank", "rank", 4, "expected a safe integer", $x$6, false);
        } else {
          $f$5 = $x$6;
        }
      }
    }
  } else {
    $f$5 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "rank", "rank", 1, "missing key \"rank\"", v, false);
  }
  if ($f$5 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$7;
  const $x$8 = v["title"];
  if ($x$8 !== undefined) {
    if ($deep$4) {
      $f$7 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "title", "title", 5, "the depth limit is reached", $x$8, false);
    } else {
      if (typeof $x$8 !== "string") {
        $f$7 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "title", "title", 0, "expected a string", $x$8, false);
      } else {
        $f$7 = $x$8;
      }
    }
  } else {
    $f$7 = Schema$compiledFail(c, Schema$pathAt(p, k, n), "title", "title", 1, "missing key \"title\"", v, false);
  }
  if ($f$7 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { rank: $f$5, title: $f$7 };
};
const JsonDerivedDce$$codec1$$parseWith = ($o, $t) => Schema$compiledParse($o, null, JsonDerivedDce$$codec1$$read, $t);
const JsonDerivedDce$$codec1$$parse = ($t) => JsonDerivedDce$$codec1$$parseWith(Schema$defaultOptions, $t);
const JsonDerivedDce$title = (text$1) => {
  const $t$1 = JsonDerivedDce$$codec1$$parse(text$1);
  if ($t$1.$ === "Ok") {
    const entry$2 = $t$1.a;
    return Basics$append(entry$2.title, String$fromInt(entry$2.rank));
  } else {
    const issues$3 = $t$1.a;
    return String$fromInt(issues$3.length);
  }
};
const JsonDerivedDce$main = Node$printLines([JsonDerivedDce$title("{\"title\":\"t\",\"rank\":1}")]);
export { JsonDerivedDce$main };
//# sourceMappingURL=JsonDerivedDce.mjs.map
