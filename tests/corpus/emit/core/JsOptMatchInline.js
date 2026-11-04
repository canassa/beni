import { Js$optNone } from "./_core/Js.mjs";
const JsOptMatchInline$Maybe$Nothing = { $: "Nothing", a: null };
const JsOptMatchInline$literal = (slot$1) => slot$1 !== Js$optNone ? slot$1 + 2 : 0 - 1;
const JsOptMatchInline$generic = (slot$1) => {
  let $t$2;
  if (slot$1 !== Js$optNone) {
    const $t$1 = slot$1 && slot$1.$opt === Js$optNone ? slot$1.$previous : slot$1;
    $t$2 = { $: "Just", a: $t$1 };
  } else {
    $t$2 = JsOptMatchInline$Maybe$Nothing;
  }
  return $t$2;
};
const JsOptMatchInline$pattern = (slot$1) => {
  let $t$1;
  if (slot$1 !== Js$optNone) {
    const x$2 = slot$1.a;
    const y$3 = slot$1.b;
    $t$1 = x$2 + y$3;
  } else {
    $t$1 = 0;
  }
  return $t$1;
};
const JsOptMatchInline$statements = (counter$1, slot$2) => {
  let $t$1;
  if (slot$2 !== Js$optNone) {
    counter$1.v = counter$1.v + 1;
    $t$1 = slot$2;
  } else {
    counter$1.v = counter$1.v + 10;
    $t$1 = 0 - 1;
  }
  return $t$1;
};
const JsOptMatchInline$variables = (slot$1, missing$2, present$3) => slot$1 !== Js$optNone ? present$3(slot$1 && slot$1.$opt === Js$optNone ? slot$1.$previous : slot$1) : missing$2(null);
export { JsOptMatchInline$literal, JsOptMatchInline$generic, JsOptMatchInline$pattern, JsOptMatchInline$statements, JsOptMatchInline$variables };
//# sourceMappingURL=JsOptMatchInline.mjs.map
