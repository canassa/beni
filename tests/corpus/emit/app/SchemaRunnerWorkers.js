import { Schema$pathAt, Schema$compiledFail, Schema$declared, Schema$checkedInput, Schema$encodedIdentity, Schema$typedIdentity, Schema$encodedCheck, Schema$typedCheck, Schema$decodeSlot, Schema$writeValueSlot, Schema$argument, Schema$decode, Schema$write } from "./_core/Schema.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
import { Js$optNone } from "./_core/Js.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
import { String$fromInt } from "./_core/String.mjs";
const SchemaRunnerWorkers$Maybe$Nothing = { $: "Nothing", a: null };
const SchemaRunnerWorkers$Schema$Missing = { $: "Missing", a: null };
const SchemaRunnerWorkers$Point$$decode = (c, d, p, k, n, v) => {
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.x;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(["[{\"label\":[\"n\",0,\"s\"],\"x\":\"i\"},[{\"Missing\":[],\"Present\":[0]}]]", [], Js$Any$pack, Js$optNone], c, Schema$pathAt(p, k, n), "x", "x", 5, "the depth limit is reached", $x$4, false);
  } else {
    if (!globalThis.Number.isSafeInteger($x$4)) {
      $s$3 = Schema$compiledFail("[\"i\",[]]", c, Schema$pathAt(p, k, n), "x", "x", 4, "expected a safe integer", $x$4, false);
    } else {
      $s$3 = $x$4;
    }
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$5;
  const $x$6 = v.label;
  if ($x$6.$ === "Missing") {
    $s$5 = $x$6;
  } else {
    const $a$7 = $x$6.a;
    let $y$8;
    if ($deep$2) {
      $y$8 = Schema$compiledFail(["[{\"label\":[\"n\",0,\"s\"],\"x\":\"i\"},[{\"Missing\":[],\"Present\":[0]}]]", [], Js$Any$pack, Js$optNone], c, Schema$pathAt(p, k, n), "label", "label", 5, "the depth limit is reached", $a$7, false);
    } else {
      $y$8 = $a$7;
    }
    $s$5 = $y$8 === c.fail ? c.fail : { $: "Present", a: $y$8 };
  }
  if ($s$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { label: $s$5, x: $s$3 };
};
const SchemaRunnerWorkers$Point$$writeValue = (c, d, p, k, n, v) => {
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.x;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(["[{\"label\":[\"n\",0,\"s\"],\"x\":\"i\"},[{\"Missing\":[],\"Present\":[0]}]]", [], Js$Any$pack, Js$optNone], c, Schema$pathAt(p, k, n), "x", "x", 5, "the depth limit is reached", $x$4, false);
  } else {
    if (!globalThis.Number.isSafeInteger($x$4)) {
      $s$3 = Schema$compiledFail("[\"i\",[]]", c, Schema$pathAt(p, k, n), "x", "x", 4, "expected a safe integer", $x$4, false);
    } else {
      $s$3 = $x$4;
    }
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$5;
  const $x$6 = v.label;
  if ($x$6.$ === "Missing") {
    $s$5 = undefined;
  } else {
    const $a$7 = $x$6.a;
    if ($deep$2) {
      $s$5 = Schema$compiledFail(["[{\"label\":[\"n\",0,\"s\"],\"x\":\"i\"},[{\"Missing\":[],\"Present\":[0]}]]", [], Js$Any$pack, Js$optNone], c, Schema$pathAt(p, k, n), "label", "label", 5, "the depth limit is reached", $a$7, false);
    } else {
      $s$5 = $a$7;
    }
  }
  if ($s$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  const $o$8 = globalThis.Object.create(null);
  $o$8["x"] = $s$3;
  if ($s$5 !== undefined) {
    $o$8["label"] = $s$5;
  }
  return $o$8;
};
const SchemaRunnerWorkers$Point$$declared = Schema$declared(($input$1) => Schema$checkedInput(["[{\"label\":[\"n\",0,\"s\"],\"x\":\"i\"},[{\"Missing\":[],\"Present\":[0]}]]", [], Js$Any$pack, Js$optNone], $input$1), ($input$2) => Schema$checkedInput(["[{\"label\":[\"n\",0,\"s\"],\"x\":\"i\"},[{\"Missing\":[],\"Present\":[0]}]]", [], Js$Any$pack, Js$optNone], $input$2), "{" + "label" + "=" + ("core:Schema.Presence" + "(" + ("" + "core:String.String") + ")") + "," + "x" + "=" + "core:Basics.Int" + "}", "{" + "label" + "=" + ("core:Schema.Presence" + "(" + ("" + "core:String.String") + ")") + "," + "x" + "=" + "core:Basics.Int" + "}", () => undefined, SchemaRunnerWorkers$Maybe$Nothing, SchemaRunnerWorkers$Maybe$Nothing, [], { $: "Just", a: SchemaRunnerWorkers$Point$$decode }, SchemaRunnerWorkers$Maybe$Nothing, SchemaRunnerWorkers$Maybe$Nothing, { $: "Just", a: SchemaRunnerWorkers$Point$$writeValue }, SchemaRunnerWorkers$Maybe$Nothing);
const SchemaRunnerWorkers$Point$$schema = ($u$3) => SchemaRunnerWorkers$Point$$declared;
const SchemaRunnerWorkers$Pair$$decode = (c, d, p, k, n, v, $s0, $check0, $check1) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.left;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(["[{\"left\":[\"p\",0],\"right\":[\"p\",0]},[]]", [$check0, $check1], Js$Any$pack, Js$optNone], c, $here, "left", "left", 5, "the depth limit is reached", $x$4, false);
  } else {
    $s$3 = $s0(c, d + 1, $here, "left", "left", $x$4);
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$5;
  const $x$6 = v.right;
  if ($deep$2) {
    $s$5 = Schema$compiledFail(["[{\"left\":[\"p\",0],\"right\":[\"p\",0]},[]]", [$check0, $check1], Js$Any$pack, Js$optNone], c, $here, "right", "right", 5, "the depth limit is reached", $x$6, false);
  } else {
    $s$5 = $s0(c, d + 1, $here, "right", "right", $x$6);
  }
  if ($s$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  return { left: $s$3, right: $s$5 };
};
const SchemaRunnerWorkers$Pair$$writeValue = (c, d, p, k, n, v, $s0, $check0, $check1) => {
  const $here = Schema$pathAt(p, k, n);
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.left;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(["[{\"left\":[\"p\",1],\"right\":[\"p\",1]},[]]", [$check0, $check1], Js$Any$pack, Js$optNone], c, $here, "left", "left", 5, "the depth limit is reached", $x$4, false);
  } else {
    $s$3 = $s0(c, d + 1, $here, "left", "left", $x$4);
  }
  if ($s$3 === c.fail && !c.all) {
    return c.fail;
  }
  let $s$5;
  const $x$6 = v.right;
  if ($deep$2) {
    $s$5 = Schema$compiledFail(["[{\"left\":[\"p\",1],\"right\":[\"p\",1]},[]]", [$check0, $check1], Js$Any$pack, Js$optNone], c, $here, "right", "right", 5, "the depth limit is reached", $x$6, false);
  } else {
    $s$5 = $s0(c, d + 1, $here, "right", "right", $x$6);
  }
  if ($s$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  const $o$7 = globalThis.Object.create(null);
  $o$7["left"] = $s$3;
  $o$7["right"] = $s$5;
  return $o$7;
};
const SchemaRunnerWorkers$Pair$$schema = ($s0) => Schema$declared(($input$15) => Schema$checkedInput(["[{\"left\":[\"p\",0],\"right\":[\"p\",0]},[]]", [Schema$encodedCheck($s0), Schema$typedCheck($s0)], Js$Any$pack, Js$optNone], $input$15), ($input$16) => Schema$checkedInput(["[{\"left\":[\"p\",1],\"right\":[\"p\",1]},[]]", [Schema$encodedCheck($s0), Schema$typedCheck($s0)], Js$Any$pack, Js$optNone], $input$16), "{" + "left" + "=" + Schema$encodedIdentity($s0) + "," + "right" + "=" + Schema$encodedIdentity($s0) + "}", "{" + "left" + "=" + Schema$typedIdentity($s0) + "," + "right" + "=" + Schema$typedIdentity($s0) + "}", () => undefined, SchemaRunnerWorkers$Maybe$Nothing, SchemaRunnerWorkers$Maybe$Nothing, [Schema$argument($s0)], { $: "Just", a: (($w$1) => ($c$2, $d$3, $p$4, $k$5, $n$6, $v$7) => SchemaRunnerWorkers$Pair$$decode($c$2, $d$3, $p$4, $k$5, $n$6, $v$7, $w$1, Schema$encodedCheck($s0), Schema$typedCheck($s0)))(Schema$decodeSlot($s0)) }, SchemaRunnerWorkers$Maybe$Nothing, SchemaRunnerWorkers$Maybe$Nothing, { $: "Just", a: (($w$8) => ($c$9, $d$10, $p$11, $k$12, $n$13, $v$14) => SchemaRunnerWorkers$Pair$$writeValue($c$9, $d$10, $p$11, $k$12, $n$13, $v$14, $w$8, Schema$encodedCheck($s0), Schema$typedCheck($s0)))(Schema$writeValueSlot($s0)) }, SchemaRunnerWorkers$Maybe$Nothing);
const SchemaRunnerWorkers$main = (() => {
  const point$1 = { label: SchemaRunnerWorkers$Schema$Missing, x: 1 };
  const $t$1 = Schema$decode(SchemaRunnerWorkers$Point$$schema(null), point$1);
  let $t$2;
  if ($t$1.$ === "Ok") {
    const p$2 = $t$1.a;
    $t$2 = String$fromInt(p$2.x);
  } else {
    $t$2 = "failed";
  }
  return Node$printLines([$t$2, Schema$write(SchemaRunnerWorkers$Pair$$schema(SchemaRunnerWorkers$Point$$schema(null)), { left: point$1, right: point$1 }).$ === "Ok" ? "written" : "failed"]);
})();
export { SchemaRunnerWorkers$main };
//# sourceMappingURL=SchemaRunnerWorkers.mjs.map
