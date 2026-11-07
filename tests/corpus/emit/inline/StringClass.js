import { Inline$root, Inline$own, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
import { Debug$logAs } from "./_core/Debug.mjs";
const StringClass$main = ($id$1) => {
  const $root$2 = Inline$root("root");
  const $init$3 = { name: "cold" };
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main class=\"fixed &amp; &quot;quoted&quot;\"><p id=dynamic>dynamic</p><textarea id=control></textarea><button id=set>set</button><button id=clear>clear");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[[]]];
  Inline$entry(() => {
    const $t$8 = Debug$logAs("[\"s\",[]]", "class value", $model$4.name);
    const $attributeNode$9 = $elements$6[0];
    const $attributeValue$10 = $t$8;
    if ($attributeNode$9.getAttribute("class") !== $attributeValue$10) {
      $attributeNode$9.setAttribute("class", $attributeValue$10);
    }
    const $t$11 = $model$4.name;
    const $attributeNode$12 = $elements$6[1];
    const $attributeValue$13 = $t$11;
    if ($attributeNode$12.getAttribute("class") !== $attributeValue$13) {
      $attributeNode$12.setAttribute("class", $attributeValue$13);
    }
  }, $table$7[0][0]);
  Inline$on($elements$6[2], () => {
    const $before$14 = $model$4;
    $before$14.name = "hot & \"quoted\"";
    Inline$pass($table$7[0][0]);
  });
  Inline$on($elements$6[3], () => {
    const $before$15 = $model$4;
    $before$15.name = "";
    Inline$pass($table$7[0][0]);
  });
  Inline$first();
};
export { StringClass$main };
//# sourceMappingURL=StringClass.mjs.map
