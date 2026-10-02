import { Schema$conversion, Schema$issue, Schema$fields, Schema$list, Schema$field, Schema$nullable, Schema$string, Schema$mapping, Schema$record, Schema$compiledFail, Schema$pathAt, Schema$readSlot, Schema$compiledParse, Schema$defaultOptions, Schema$writeSlot, Schema$compiledPrint, Schema$converted, Schema$value, Schema$compiledForward, Schema$compiledBackward, Schema$belowBackward, Schema$printableWithin } from "./_core/Schema.mjs";
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
const SchemaWorkers$Page$$schema = ($s0) => Schema$record(Schema$field(Schema$field(Schema$fields, "items", Schema$list($s0)), "note", Schema$nullable(Schema$string)), Schema$mapping(($p$2) => ({ items: $p$2.a.b, note: $p$2.b }), ($r$3) => ({ a: { a: null, b: $r$3.items }, b: $r$3.note })), Schema$mapping(($p$4) => ({ items: $p$4.a.b, note: $p$4.b }), ($r$5) => ({ a: { a: null, b: $r$5.items }, b: $r$5.note })));
const SchemaWorkers$Page$$read = (c, d, p, k, n, v, $s0) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$6 = c.issues.length;
  if (c.reject) {
    for (const $key$7 of globalThis.Object.keys(v)) {
      if ($key$7 !== "items" && $key$7 !== "note") {
        Schema$compiledFail(c, $here, $key$7, $key$7, 2, "unexpected key \"" + $key$7 + "\"", v[$key$7], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$9 = d >= c.max;
  let $f$10;
  const $x$11 = v["items"];
  if ($x$11 !== undefined) {
    if ($deep$9) {
      $f$10 = Schema$compiledFail(c, $here, "items", "items", 5, "the depth limit is reached", $x$11, false);
    } else {
      $f$10 = SchemaWorkers$Page$$read$1(c, d + 1, $here, "items", "items", $x$11, $s0);
    }
  } else {
    $f$10 = Schema$compiledFail(c, $here, "items", "items", 1, "missing key \"items\"", v, false);
  }
  if ($f$10 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$12;
  const $x$13 = v["note"];
  if ($x$13 !== undefined) {
    if ($deep$9) {
      $f$12 = Schema$compiledFail(c, $here, "note", "note", 5, "the depth limit is reached", $x$13, false);
    } else {
      if ($x$13 === null) {
        $f$12 = SchemaWorkers$Schema$Null;
      } else {
        let $y$14;
        if (typeof $x$13 !== "string") {
          $y$14 = Schema$compiledFail(c, $here, "note", "note", 0, "expected a string", $x$13, false);
        } else {
          $y$14 = $x$13;
        }
        $f$12 = $y$14 === c.fail ? c.fail : { $: "NonNull", a: $y$14 };
      }
    }
  } else {
    $f$12 = Schema$compiledFail(c, $here, "note", "note", 1, "missing key \"note\"", v, false);
  }
  if ($f$12 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$6) {
    return c.fail;
  }
  return { items: $f$10, note: $f$12 };
};
const SchemaWorkers$Page$$read$1 = (c, d, p, k, n, v, $s0) => {
  if (!globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an array", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$15 = c.issues.length;
  const $len$16 = v.length;
  const $deep$17 = d >= c.max;
  const $out$18 = [];
  let $i$19 = 0;
  while (!($i$19 >= $len$16)) {
    const $x$20 = v[$i$19];
    let $y$21;
    if ($deep$17) {
      $y$21 = Schema$compiledFail(c, $here, $i$19, $i$19, 5, "the depth limit is reached", $x$20, false);
    } else {
      $y$21 = $s0(c, d + 1, $here, $i$19, $i$19, $x$20);
    }
    if ($y$21 === c.fail) {
      if (!c.all) {
        return c.fail;
      }
    } else {
      $out$18.push($y$21);
    }
    $i$19 = $i$19 + 1;
  }
  if (c.issues.length > $before$15) {
    return c.fail;
  }
  return $out$18;
};
const SchemaWorkers$Page$$parseWith = ($s0, $o, $t) => Schema$compiledParse($o, [$s0], ($c$22, $d$23, $p$24, $k$25, $n$26, $v$27) => SchemaWorkers$Page$$read($c$22, $d$23, $p$24, $k$25, $n$26, $v$27, Schema$readSlot($s0)), $t);
const SchemaWorkers$Page$$parse = ($s0, $t) => SchemaWorkers$Page$$parseWith($s0, Schema$defaultOptions, $t);
const SchemaWorkers$Page$$write = (c, d, p, k, n, v, $s0) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$28 = c.issues.length;
  const $deep$29 = d >= c.max;
  let $s$30;
  const $x$31 = v.items;
  if ($deep$29) {
    $s$30 = Schema$compiledFail(c, $here, "items", "items", 5, "the depth limit is reached", $x$31, false);
  } else {
    $s$30 = SchemaWorkers$Page$$write$1(c, d + 1, $here, "items", "items", $x$31, $s0);
  }
  if ($s$30 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$32;
  const $x$33 = v.note;
  if ($deep$29) {
    $s$32 = Schema$compiledFail(c, $here, "note", "note", 5, "the depth limit is reached", $x$33, false);
  } else {
    if ($x$33.$ === "Null") {
      $s$32 = null;
    } else {
      const $a$34 = $x$33.a;
      $s$32 = $a$34;
    }
  }
  if ($s$32 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$28) {
    return c.fail;
  }
  const $o$35 = {};
  $o$35["items"] = $s$30;
  $o$35["note"] = $s$32;
  return $o$35;
};
const SchemaWorkers$Page$$write$1 = (c, d, p, k, n, v, $s0) => {
  const $here = Schema$pathAt(p, k, n);
  const $xs$36 = globalThis.Array.isArray(v) ? v : v.$plain();
  const $before$37 = c.issues.length;
  const $len$38 = $xs$36.length;
  const $deep$39 = d >= c.max;
  const $out$40 = [];
  let $i$41 = 0;
  while (!($i$41 >= $len$38)) {
    const $x$42 = $xs$36[$i$41];
    let $y$43;
    if ($deep$39) {
      $y$43 = Schema$compiledFail(c, $here, $i$41, $i$41, 5, "the depth limit is reached", $x$42, false);
    } else {
      $y$43 = $s0(c, d + 1, $here, $i$41, $i$41, $x$42);
    }
    if ($y$43 === c.fail) {
      if (!c.all) {
        return c.fail;
      }
    } else {
      $out$40.push($y$43);
    }
    $i$41 = $i$41 + 1;
  }
  if (c.issues.length > $before$37) {
    return c.fail;
  }
  return $out$40;
};
const SchemaWorkers$Page$$printWith = ($s0, $o, $t) => Schema$compiledPrint($o, [$s0], ($c$44, $d$45, $p$46, $k$47, $n$48, $v$49) => SchemaWorkers$Page$$write($c$44, $d$45, $p$46, $k$47, $n$48, $v$49, Schema$writeSlot($s0)), $t);
const SchemaWorkers$Page$$print = ($s0, $t) => SchemaWorkers$Page$$printWith($s0, Schema$defaultOptions, $t);
const SchemaWorkers$Box$$via$0 = SchemaWorkers$decimalInt;
const SchemaWorkers$Box$$description = Schema$record(Schema$field(Schema$field(Schema$fields, "count", Schema$converted(Schema$string, SchemaWorkers$Box$$via$0)), "raw", Schema$value), Schema$mapping(($p$50) => ({ count: $p$50.a.b, raw: $p$50.b }), ($r$51) => ({ a: { a: null, b: $r$51.count }, b: $r$51.raw })), Schema$mapping(($p$52) => ({ count: $p$52.a.b, raw: $p$52.b }), ($r$53) => ({ a: { a: null, b: $r$53.count }, b: $r$53.raw })));
const SchemaWorkers$Box$$schema = ($u$54) => SchemaWorkers$Box$$description;
const SchemaWorkers$Box$$read = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$55 = c.issues.length;
  if (c.reject) {
    for (const $key$56 of globalThis.Object.keys(v)) {
      if ($key$56 !== "count" && $key$56 !== "raw") {
        Schema$compiledFail(c, $here, $key$56, $key$56, 2, "unexpected key \"" + $key$56 + "\"", v[$key$56], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$58 = d >= c.max;
  let $f$59;
  const $x$60 = v["count"];
  if ($x$60 !== undefined) {
    if ($deep$58) {
      $f$59 = Schema$compiledFail(c, $here, "count", "count", 5, "the depth limit is reached", $x$60, false);
    } else {
      let $b$61;
      if (typeof $x$60 !== "string") {
        $b$61 = Schema$compiledFail(c, $here, "count", "count", 0, "expected a string", $x$60, false);
      } else {
        $b$61 = $x$60;
      }
      $f$59 = $b$61 === c.fail ? c.fail : Schema$compiledForward(c, $here, "count", "count", SchemaWorkers$Box$$via$0, $b$61);
    }
  } else {
    $f$59 = Schema$compiledFail(c, $here, "count", "count", 1, "missing key \"count\"", v, false);
  }
  if ($f$59 === c.fail && !c.all) {
    return c.fail;
  }
  let $f$62;
  const $x$63 = v["raw"];
  if ($x$63 !== undefined) {
    if ($deep$58) {
      $f$62 = Schema$compiledFail(c, $here, "raw", "raw", 5, "the depth limit is reached", $x$63, false);
    } else {
      $f$62 = $x$63;
    }
  } else {
    $f$62 = Schema$compiledFail(c, $here, "raw", "raw", 1, "missing key \"raw\"", v, false);
  }
  if ($f$62 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$55) {
    return c.fail;
  }
  return { count: $f$59, raw: $f$62 };
};
const SchemaWorkers$Box$$parseWith = ($o, $t) => Schema$compiledParse($o, [], SchemaWorkers$Box$$read, $t);
const SchemaWorkers$Box$$parse = ($t) => SchemaWorkers$Box$$parseWith(Schema$defaultOptions, $t);
const SchemaWorkers$Box$$write = (c, d, p, k, n, v) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$64 = c.issues.length;
  const $deep$65 = d >= c.max;
  let $s$66;
  const $x$67 = v.count;
  if ($deep$65) {
    $s$66 = Schema$compiledFail(c, $here, "count", "count", 5, "the depth limit is reached", $x$67, false);
  } else {
    const $b$68 = Schema$compiledBackward(c, $here, "count", "count", SchemaWorkers$Box$$via$0, $x$67);
    if ($b$68 === c.fail) {
      $s$66 = c.fail;
    } else {
      const $cv$69 = Schema$belowBackward(c);
      $s$66 = $b$68;
    }
  }
  if ($s$66 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$70;
  const $x$71 = v.raw;
  if ($deep$65) {
    $s$70 = Schema$compiledFail(c, $here, "raw", "raw", 5, "the depth limit is reached", $x$71, false);
  } else {
    const $printable$72 = Schema$printableWithin(c, d + 1, $x$71);
    if ($printable$72 === 1) {
      $s$70 = Schema$compiledFail(c, $here, "raw", "raw", 5, "the value nests deeper than the depth limit", $x$71, true);
    } else {
      if ($printable$72 === 2) {
        $s$70 = Schema$compiledFail(c, $here, "raw", "raw", 10, "the value holds NaN or an infinity, which JSON has no number for", $x$71, true);
      } else {
        $s$70 = $x$71;
      }
    }
  }
  if ($s$70 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$64) {
    return c.fail;
  }
  const $o$73 = {};
  $o$73["count"] = $s$66;
  $o$73["raw"] = $s$70;
  return $o$73;
};
const SchemaWorkers$Box$$printWith = ($o, $t) => Schema$compiledPrint($o, [], SchemaWorkers$Box$$write, $t);
const SchemaWorkers$Box$$print = ($t) => SchemaWorkers$Box$$printWith(Schema$defaultOptions, $t);
const SchemaWorkers$Pages$$description = Schema$record(Schema$field(Schema$fields, "boxes", SchemaWorkers$Page$$schema(SchemaWorkers$Box$$description)), Schema$mapping(($p$74) => ({ boxes: $p$74.b }), ($r$75) => ({ a: null, b: $r$75.boxes })), Schema$mapping(($p$76) => ({ boxes: $p$76.b }), ($r$77) => ({ a: null, b: $r$77.boxes })));
const SchemaWorkers$Pages$$schema = ($u$78) => SchemaWorkers$Pages$$description;
const SchemaWorkers$Pages$$read = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return Schema$compiledFail(c, p, k, n, 0, "expected an object", v, false);
  }
  const $here = Schema$pathAt(p, k, n);
  const $before$79 = c.issues.length;
  if (c.reject) {
    for (const $key$80 of globalThis.Object.keys(v)) {
      if ($key$80 !== "boxes") {
        Schema$compiledFail(c, $here, $key$80, $key$80, 2, "unexpected key \"" + $key$80 + "\"", v[$key$80], false);
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$82 = d >= c.max;
  let $f$83;
  const $x$84 = v["boxes"];
  if ($x$84 !== undefined) {
    if ($deep$82) {
      $f$83 = Schema$compiledFail(c, $here, "boxes", "boxes", 5, "the depth limit is reached", $x$84, false);
    } else {
      $f$83 = SchemaWorkers$Page$$read(c, d + 1, $here, "boxes", "boxes", $x$84, SchemaWorkers$Box$$read);
    }
  } else {
    $f$83 = Schema$compiledFail(c, $here, "boxes", "boxes", 1, "missing key \"boxes\"", v, false);
  }
  if ($f$83 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$79) {
    return c.fail;
  }
  return { boxes: $f$83 };
};
const SchemaWorkers$Pages$$parseWith = ($o, $t) => Schema$compiledParse($o, [], SchemaWorkers$Pages$$read, $t);
const SchemaWorkers$Pages$$parse = ($t) => SchemaWorkers$Pages$$parseWith(Schema$defaultOptions, $t);
const SchemaWorkers$Pages$$write = (c, d, p, k, n, v) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$85 = c.issues.length;
  const $deep$86 = d >= c.max;
  let $s$87;
  const $x$88 = v.boxes;
  if ($deep$86) {
    $s$87 = Schema$compiledFail(c, $here, "boxes", "boxes", 5, "the depth limit is reached", $x$88, false);
  } else {
    $s$87 = SchemaWorkers$Page$$write(c, d + 1, $here, "boxes", "boxes", $x$88, SchemaWorkers$Box$$write);
  }
  if ($s$87 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$85) {
    return c.fail;
  }
  const $o$89 = {};
  $o$89["boxes"] = $s$87;
  return $o$89;
};
const SchemaWorkers$Pages$$printWith = ($o, $t) => Schema$compiledPrint($o, [], SchemaWorkers$Pages$$write, $t);
const SchemaWorkers$Pages$$print = ($t) => SchemaWorkers$Pages$$printWith(Schema$defaultOptions, $t);
const SchemaWorkers$main = Node$printLines([]);
export { SchemaWorkers$main, SchemaWorkers$Page$$schema, SchemaWorkers$Page$$read, SchemaWorkers$Page$$parse, SchemaWorkers$Page$$parseWith, SchemaWorkers$Page$$write, SchemaWorkers$Page$$print, SchemaWorkers$Page$$printWith, SchemaWorkers$Box$$schema, SchemaWorkers$Box$$read, SchemaWorkers$Box$$parse, SchemaWorkers$Box$$parseWith, SchemaWorkers$Box$$write, SchemaWorkers$Box$$print, SchemaWorkers$Box$$printWith, SchemaWorkers$Pages$$schema, SchemaWorkers$Pages$$read, SchemaWorkers$Pages$$parse, SchemaWorkers$Pages$$parseWith, SchemaWorkers$Pages$$write, SchemaWorkers$Pages$$print, SchemaWorkers$Pages$$printWith };
//# sourceMappingURL=SchemaWorkers.mjs.map
