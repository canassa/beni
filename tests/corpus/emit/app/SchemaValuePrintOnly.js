import { Schema$pathAt, Schema$compiledFail, Schema$declared, Schema$checkedInput, Schema$encodedIdentity, Schema$typedIdentity, Schema$encodedCheck, Schema$typedCheck, Schema$writeSlot, Schema$argument, Schema$print } from "./_core/Schema.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
import { Js$optNone } from "./_core/Js.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const SchemaValuePrintOnly$Maybe$Nothing = { $: "Nothing", a: null };
const SchemaValuePrintOnly$Point$$write = (c, d, p, k, n, v) => {
  const $before$1 = c.issues.length;
  const $deep$2 = d >= c.max;
  let $s$3;
  const $x$4 = v.x;
  if ($deep$2) {
    $s$3 = Schema$compiledFail(["[{\"x\":\"i\",\"y\":\"i\"},[]]", [], Js$Any$pack, Js$optNone], c, Schema$pathAt(p, k, n), "x", "x", 5, "the depth limit is reached", $x$4, false);
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
  const $x$6 = v.y;
  if ($deep$2) {
    $s$5 = Schema$compiledFail(["[{\"x\":\"i\",\"y\":\"i\"},[]]", [], Js$Any$pack, Js$optNone], c, Schema$pathAt(p, k, n), "y", "y", 5, "the depth limit is reached", $x$6, false);
  } else {
    if (!globalThis.Number.isSafeInteger($x$6)) {
      $s$5 = Schema$compiledFail("[\"i\",[]]", c, Schema$pathAt(p, k, n), "y", "y", 4, "expected a safe integer", $x$6, false);
    } else {
      $s$5 = $x$6;
    }
  }
  if ($s$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (c.issues.length > $before$1) {
    return c.fail;
  }
  const $o$7 = {};
  $o$7["x"] = $s$3;
  $o$7["y"] = $s$5;
  return $o$7;
};
const SchemaValuePrintOnly$Point$$declared = Schema$declared(($input$1) => Schema$checkedInput(["[{\"x\":\"i\",\"y\":\"i\"},[]]", [], Js$Any$pack, Js$optNone], $input$1), ($input$2) => Schema$checkedInput(["[{\"x\":\"i\",\"y\":\"i\"},[]]", [], Js$Any$pack, Js$optNone], $input$2), "{" + "x" + "=" + "core:Basics.Int" + "," + "y" + "=" + "core:Basics.Int" + "}", "{" + "x" + "=" + "core:Basics.Int" + "," + "y" + "=" + "core:Basics.Int" + "}", () => undefined, SchemaValuePrintOnly$Maybe$Nothing, { $: "Just", a: SchemaValuePrintOnly$Point$$write }, [], SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing);
const SchemaValuePrintOnly$Point$$schema = ($u$3) => SchemaValuePrintOnly$Point$$declared;
const SchemaValuePrintOnly$Pair$$write = (c, d, p, k, n, v, $s0, $check0, $check1) => {
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
  const $o$7 = {};
  $o$7["left"] = $s$3;
  $o$7["right"] = $s$5;
  return $o$7;
};
const SchemaValuePrintOnly$Pair$$schema = ($s0) => Schema$declared(($input$8) => Schema$checkedInput(["[{\"left\":[\"p\",0],\"right\":[\"p\",0]},[]]", [Schema$encodedCheck($s0), Schema$typedCheck($s0)], Js$Any$pack, Js$optNone], $input$8), ($input$9) => Schema$checkedInput(["[{\"left\":[\"p\",1],\"right\":[\"p\",1]},[]]", [Schema$encodedCheck($s0), Schema$typedCheck($s0)], Js$Any$pack, Js$optNone], $input$9), "{" + "left" + "=" + Schema$encodedIdentity($s0) + "," + "right" + "=" + Schema$encodedIdentity($s0) + "}", "{" + "left" + "=" + Schema$typedIdentity($s0) + "," + "right" + "=" + Schema$typedIdentity($s0) + "}", () => undefined, SchemaValuePrintOnly$Maybe$Nothing, { $: "Just", a: (($w$1) => ($c$2, $d$3, $p$4, $k$5, $n$6, $v$7) => SchemaValuePrintOnly$Pair$$write($c$2, $d$3, $p$4, $k$5, $n$6, $v$7, $w$1, Schema$encodedCheck($s0), Schema$typedCheck($s0)))(Schema$writeSlot($s0)) }, [Schema$argument($s0)], SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing, SchemaValuePrintOnly$Maybe$Nothing);
const SchemaValuePrintOnly$main = (() => {
  const point$1 = { x: 1, y: 2 };
  const $t$1 = Schema$print(SchemaValuePrintOnly$Point$$schema(null), point$1);
  let $t$2;
  if ($t$1.$ === "Ok") {
    const text$2 = $t$1.a;
    $t$2 = text$2;
  } else {
    $t$2 = "failed";
  }
  const $t$3 = Schema$print(SchemaValuePrintOnly$Pair$$schema(SchemaValuePrintOnly$Point$$schema(null)), { left: point$1, right: point$1 });
  let $t$4;
  if ($t$3.$ === "Ok") {
    const text$3 = $t$3.a;
    $t$4 = text$3;
  } else {
    $t$4 = "failed";
  }
  return Node$printLines([$t$2, $t$4]);
})();
export { SchemaValuePrintOnly$main };
//# sourceMappingURL=SchemaValuePrintOnly.mjs.map
