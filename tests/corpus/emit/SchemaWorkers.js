import { Schema$conversion, Schema$issue, Schema$fields, Schema$list, Schema$field, Schema$nullable, Schema$string, Schema$mapping, Schema$record, Schema$compiledFail, Schema$pathAt, Schema$readSlot, Schema$compiledParse, Schema$defaultOptions, Schema$writeSlot, Schema$compiledPrint, Schema$declared, Schema$converted, Schema$value, Schema$compiledForward, Schema$compiledBackward, Schema$belowBackward, Schema$printableWithin } from "./_core/Schema.mjs";
import { String$toInt, String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const SchemaWorkers$Schema$Null = { $: "Null", a: null };
const SchemaWorkers$decimalInt = Schema$conversion((s$1) => {
  const $t$1 = String$toInt(s$1);
  if ($t$1.$ === "Just") {
    const n$2 = $t$1.a;
    return { $: "Ok", a: n$2 };
  } else {
    return { $: "Err", a: [Schema$issue("not a decimal integer")] };
  }
}, (n$3) => ({ $: "Ok", a: String$fromInt(n$3) }));
const SchemaWorkers$Page$$description = ($s0) => Schema$record(Schema$field(Schema$field(Schema$fields, "items", Schema$list($s0)), "note", Schema$nullable(Schema$string)), Schema$mapping(($p$1) => ({ items: $p$1.a.b, note: $p$1.b }), ($r$2) => ({ a: { a: null, b: $r$2.items }, b: $r$2.note })), Schema$mapping(($p$3) => ({ items: $p$3.a.b, note: $p$3.b }), ($r$4) => ({ a: { a: null, b: $r$4.items }, b: $r$4.note })));
const SchemaWorkers$Page$$read = (c, d, p, k, n, v, $s0) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "items" && $key$2 !== "note") {
        Schema$compiledFail(c, $here, $key$2, $key$2, 2, "unexpected key \"" + $key$2 + "\"", v[$key$2], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  let $f$5;
  const $x$6 = v["items"];
  if ($x$6 !== undefined) {
    if ($deep$4) {
      $f$5 = Schema$compiledFail(c, $here, "items", "items", 5, "the depth limit is reached", $x$6, false);
    } else {
      $f$5 = SchemaWorkers$Page$$read$1(c, d + 1, $here, "items", "items", $x$6, $s0);
    }
  } else {
    $f$5 = Schema$compiledFail(c, $here, "items", "items", 1, "missing key \"items\"", v, false);
  }
  if ($f$5 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$7;
  const $x$8 = v["note"];
  if ($x$8 !== undefined) {
    if ($deep$4) {
      $f$7 = Schema$compiledFail(c, $here, "note", "note", 5, "the depth limit is reached", $x$8, false);
    } else {
      if ($x$8 === null) {
        $f$7 = SchemaWorkers$Schema$Null;
      } else {
        let $y$9;
        if (typeof $x$8 !== "string") {
          $y$9 = Schema$compiledFail(c, $here, "note", "note", 0, "expected a string", $x$8, false);
        } else {
          $y$9 = $x$8;
        }
        $f$7 = $y$9 === c.fail ? c.fail : { $: "NonNull", a: $y$9 };
      }
    }
  } else {
    $f$7 = Schema$compiledFail(c, $here, "note", "note", 1, "missing key \"note\"", v, false);
  }
  if ($f$7 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { items: $f$5, note: $f$7 };
};
const SchemaWorkers$Page$$read$1 = (c, d, p, k, n, v, $s0) => {
  if (!globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an array", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$10 = c.issues.length;
  const $len$11 = v.length;
  const $deep$12 = d >= c.max;
  const $out$13 = [];
  let $i$14 = 0;
  while (!($i$14 >= $len$11)) {
    const $x$15 = v[$i$14];
    let $y$16;
    if ($deep$12) {
      $y$16 = Schema$compiledFail(c, $here, $i$14, $i$14, 5, "the depth limit is reached", $x$15, false);
    } else {
      $y$16 = $s0(c, d + 1, $here, $i$14, $i$14, $x$15);
    }
    if ($y$16 === c.fail) {
      if (!c.all) {
        return c.fail;
      }
    } else {
      $out$13.push($y$16);
    }
    $i$14 = $i$14 + 1;
  }
  if (c.issues.length > $before$10) {
    return c.fail;
  }
  return $out$13;
};
const SchemaWorkers$Page$$parseWith = ($s0, $o, $t) => Schema$compiledParse($o, [$s0], ($c$17, $d$18, $p$19, $k$20, $n$21, $v$22) => SchemaWorkers$Page$$read($c$17, $d$18, $p$19, $k$20, $n$21, $v$22, Schema$readSlot($s0)), $t);
const SchemaWorkers$Page$$parse = ($s0, $t) => SchemaWorkers$Page$$parseWith($s0, Schema$defaultOptions, $t);
const SchemaWorkers$Page$$write = (c, d, p, k, n, v, $s0) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.items;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(c, $here, "items", "items", 5, "the depth limit is reached", $x$4, false);
  } else {
    $s$3 = SchemaWorkers$Page$$write$1(c, d + 1, $here, "items", "items", $x$4, $s0);
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$5;
  const $x$6 = v.note;
  if ($deep$2) {
    $s$5 = Schema$compiledFail(c, $here, "note", "note", 5, "the depth limit is reached", $x$6, false);
  } else {
    if ($x$6.$ === "Null") {
      $s$5 = null;
    } else {
      const $a$7 = $x$6.a;
      $s$5 = $a$7;
    }
  }
  if ($s$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  const $o$8 = {};
  $o$8["items"] = $s$3;
  $o$8["note"] = $s$5;
  return $o$8;
};
const SchemaWorkers$Page$$write$1 = (c, d, p, k, n, v, $s0) => {
  const $here = Schema$pathAt(p, k, n);
  const $xs$9 = globalThis.Array.isArray(v) ? v : v.$plain();
  const $before$10 = c.issues.length;
  const $len$11 = $xs$9.length;
  const $deep$12 = d >= c.max;
  const $out$13 = [];
  let $i$14 = 0;
  while (!($i$14 >= $len$11)) {
    const $x$15 = $xs$9[$i$14];
    let $y$16;
    if ($deep$12) {
      $y$16 = Schema$compiledFail(c, $here, $i$14, $i$14, 5, "the depth limit is reached", $x$15, false);
    } else {
      $y$16 = $s0(c, d + 1, $here, $i$14, $i$14, $x$15);
    }
    if ($y$16 === c.fail) {
      if (!c.all) {
        return c.fail;
      }
    } else {
      $out$13.push($y$16);
    }
    $i$14 = $i$14 + 1;
  }
  if (c.issues.length > $before$10) {
    return c.fail;
  }
  return $out$13;
};
const SchemaWorkers$Page$$printWith = ($s0, $o, $t) => Schema$compiledPrint($o, [$s0], ($c$17, $d$18, $p$19, $k$20, $n$21, $v$22) => SchemaWorkers$Page$$write($c$17, $d$18, $p$19, $k$20, $n$21, $v$22, Schema$writeSlot($s0)), $t);
const SchemaWorkers$Page$$print = ($s0, $t) => SchemaWorkers$Page$$printWith($s0, Schema$defaultOptions, $t);
const SchemaWorkers$Page$$schema = ($s0) => Schema$declared(() => SchemaWorkers$Page$$description($s0), (($w$1) => ($c$2, $d$3, $p$4, $k$5, $n$6, $v$7) => SchemaWorkers$Page$$read($c$2, $d$3, $p$4, $k$5, $n$6, $v$7, $w$1))(Schema$readSlot($s0)), (($w$8) => ($c$9, $d$10, $p$11, $k$12, $n$13, $v$14) => SchemaWorkers$Page$$write($c$9, $d$10, $p$11, $k$12, $n$13, $v$14, $w$8))(Schema$writeSlot($s0)), [$s0]);
const SchemaWorkers$Box$$via$0 = SchemaWorkers$decimalInt;
const SchemaWorkers$Box$$description = Schema$record(Schema$field(Schema$field(Schema$fields, "count", Schema$converted(Schema$string, SchemaWorkers$Box$$via$0)), "raw", Schema$value), Schema$mapping(($p$1) => ({ count: $p$1.a.b, raw: $p$1.b }), ($r$2) => ({ a: { a: null, b: $r$2.count }, b: $r$2.raw })), Schema$mapping(($p$3) => ({ count: $p$3.a.b, raw: $p$3.b }), ($r$4) => ({ a: { a: null, b: $r$4.count }, b: $r$4.raw })));
const SchemaWorkers$Box$$read = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "count" && $key$2 !== "raw") {
        Schema$compiledFail(c, $here, $key$2, $key$2, 2, "unexpected key \"" + $key$2 + "\"", v[$key$2], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  let $f$5;
  const $x$6 = v["count"];
  if ($x$6 !== undefined) {
    if ($deep$4) {
      $f$5 = Schema$compiledFail(c, $here, "count", "count", 5, "the depth limit is reached", $x$6, false);
    } else {
      let $b$7;
      if (typeof $x$6 !== "string") {
        $b$7 = Schema$compiledFail(c, $here, "count", "count", 0, "expected a string", $x$6, false);
      } else {
        $b$7 = $x$6;
      }
      $f$5 = $b$7 === c.fail ? c.fail : Schema$compiledForward(c, $here, "count", "count", SchemaWorkers$Box$$via$0, $b$7);
    }
  } else {
    $f$5 = Schema$compiledFail(c, $here, "count", "count", 1, "missing key \"count\"", v, false);
  }
  if ($f$5 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$8;
  const $x$9 = v["raw"];
  if ($x$9 !== undefined) {
    if ($deep$4) {
      $f$8 = Schema$compiledFail(c, $here, "raw", "raw", 5, "the depth limit is reached", $x$9, false);
    } else {
      $f$8 = $x$9;
    }
  } else {
    $f$8 = Schema$compiledFail(c, $here, "raw", "raw", 1, "missing key \"raw\"", v, false);
  }
  if ($f$8 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { count: $f$5, raw: $f$8 };
};
const SchemaWorkers$Box$$parseWith = ($o, $t) => Schema$compiledParse($o, null, SchemaWorkers$Box$$read, $t);
const SchemaWorkers$Box$$parse = ($t) => SchemaWorkers$Box$$parseWith(Schema$defaultOptions, $t);
const SchemaWorkers$Box$$write = (c, d, p, k, n, v) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.count;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(c, $here, "count", "count", 5, "the depth limit is reached", $x$4, false);
  } else {
    const $b$5 = Schema$compiledBackward(c, $here, "count", "count", SchemaWorkers$Box$$via$0, $x$4);
    if ($b$5 === c.fail) {
      $s$3 = c.fail;
    } else {
      const $cv$6 = Schema$belowBackward(c);
      $s$3 = $b$5;
    }
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$7;
  const $x$8 = v.raw;
  if ($deep$2) {
    $s$7 = Schema$compiledFail(c, $here, "raw", "raw", 5, "the depth limit is reached", $x$8, false);
  } else {
    const $printable$9 = Schema$printableWithin(c, d + 1, $x$8);
    if ($printable$9 === 1) {
      $s$7 = Schema$compiledFail(c, $here, "raw", "raw", 5, "the value nests deeper than the depth limit", $x$8, true);
    } else {
      if ($printable$9 === 2) {
        $s$7 = Schema$compiledFail(c, $here, "raw", "raw", 10, "the value holds NaN or an infinity, which JSON has no number for", $x$8, true);
      } else {
        $s$7 = $x$8;
      }
    }
  }
  if ($s$7 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  const $o$10 = {};
  $o$10["count"] = $s$3;
  $o$10["raw"] = $s$7;
  return $o$10;
};
const SchemaWorkers$Box$$printWith = ($o, $t) => Schema$compiledPrint($o, null, SchemaWorkers$Box$$write, $t);
const SchemaWorkers$Box$$print = ($t) => SchemaWorkers$Box$$printWith(Schema$defaultOptions, $t);
const SchemaWorkers$Box$$declared = Schema$declared(() => SchemaWorkers$Box$$description, SchemaWorkers$Box$$read, SchemaWorkers$Box$$write, null);
const SchemaWorkers$Box$$schema = ($u$1) => SchemaWorkers$Box$$declared;
const SchemaWorkers$Pages$$description = Schema$record(Schema$field(Schema$fields, "boxes", SchemaWorkers$Page$$description(SchemaWorkers$Box$$description)), Schema$mapping(($p$1) => ({ boxes: $p$1.b }), ($r$2) => ({ a: null, b: $r$2.boxes })), Schema$mapping(($p$3) => ({ boxes: $p$3.b }), ($r$4) => ({ a: null, b: $r$4.boxes })));
const SchemaWorkers$Pages$$read = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "boxes") {
        Schema$compiledFail(c, $here, $key$2, $key$2, 2, "unexpected key \"" + $key$2 + "\"", v[$key$2], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  let $f$5;
  const $x$6 = v["boxes"];
  if ($x$6 !== undefined) {
    if ($deep$4) {
      $f$5 = Schema$compiledFail(c, $here, "boxes", "boxes", 5, "the depth limit is reached", $x$6, false);
    } else {
      $f$5 = SchemaWorkers$Page$$read(c, d + 1, $here, "boxes", "boxes", $x$6, SchemaWorkers$Box$$read);
    }
  } else {
    $f$5 = Schema$compiledFail(c, $here, "boxes", "boxes", 1, "missing key \"boxes\"", v, false);
  }
  if ($f$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { boxes: $f$5 };
};
const SchemaWorkers$Pages$$parseWith = ($o, $t) => Schema$compiledParse($o, null, SchemaWorkers$Pages$$read, $t);
const SchemaWorkers$Pages$$parse = ($t) => SchemaWorkers$Pages$$parseWith(Schema$defaultOptions, $t);
const SchemaWorkers$Pages$$write = (c, d, p, k, n, v) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.boxes;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(c, $here, "boxes", "boxes", 5, "the depth limit is reached", $x$4, false);
  } else {
    $s$3 = SchemaWorkers$Page$$write(c, d + 1, $here, "boxes", "boxes", $x$4, SchemaWorkers$Box$$write);
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  const $o$5 = {};
  $o$5["boxes"] = $s$3;
  return $o$5;
};
const SchemaWorkers$Pages$$printWith = ($o, $t) => Schema$compiledPrint($o, null, SchemaWorkers$Pages$$write, $t);
const SchemaWorkers$Pages$$print = ($t) => SchemaWorkers$Pages$$printWith(Schema$defaultOptions, $t);
const SchemaWorkers$Pages$$declared = Schema$declared(() => SchemaWorkers$Pages$$description, SchemaWorkers$Pages$$read, SchemaWorkers$Pages$$write, null);
const SchemaWorkers$Pages$$schema = ($u$1) => SchemaWorkers$Pages$$declared;
const SchemaWorkers$main = Node$printLines([]);
export { SchemaWorkers$main, SchemaWorkers$Page$$schema, SchemaWorkers$Page$$description, SchemaWorkers$Page$$read, SchemaWorkers$Page$$parse, SchemaWorkers$Page$$parseWith, SchemaWorkers$Page$$write, SchemaWorkers$Page$$print, SchemaWorkers$Page$$printWith, SchemaWorkers$Box$$schema, SchemaWorkers$Box$$description, SchemaWorkers$Box$$read, SchemaWorkers$Box$$parse, SchemaWorkers$Box$$parseWith, SchemaWorkers$Box$$write, SchemaWorkers$Box$$print, SchemaWorkers$Box$$printWith, SchemaWorkers$Pages$$schema, SchemaWorkers$Pages$$description, SchemaWorkers$Pages$$read, SchemaWorkers$Pages$$parse, SchemaWorkers$Pages$$parseWith, SchemaWorkers$Pages$$write, SchemaWorkers$Pages$$print, SchemaWorkers$Pages$$printWith };
//# sourceMappingURL=SchemaWorkers.mjs.map
