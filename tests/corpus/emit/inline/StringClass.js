import { Inline$namedRoot, Inline$root, Inline$own, Inline$bucket, Inline$entry, Inline$pass, Inline$unchanged, Inline$guarded, Inline$first, Inline$client } from "./_platform/Inline.mjs";
import { Debug$logAs } from "./_core/Debug.mjs";
const StringClass$main = Inline$client(($id$1) => {
  const $root$2 = Inline$root(Inline$namedRoot("root"));
  const $init$3 = { name: "cold" };
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main class=\"fixed &amp; &quot;quoted&quot;\"><p id=dynamic>dynamic</p><textarea id=control></textarea><button id=set>set</button><button id=clear>clear");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[Inline$bucket(null)]];
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
  }, [$table$7[0][0]]);
  const $listener$16 = () => {
    const $before$14 = $model$4;
    $before$14.name = "hot & \"quoted\"";
    Inline$pass($table$7[0][0]);
  };
  const $reader$17 = Inline$unchanged;
  $elements$6[2].addEventListener("click", ($event$18) => {
    Inline$guarded($listener$16, $event$18, $reader$17);
  });
  const $listener$19 = () => {
    const $before$15 = $model$4;
    $before$15.name = "";
    Inline$pass($table$7[0][0]);
  };
  const $reader$20 = Inline$unchanged;
  $elements$6[3].addEventListener("click", ($event$21) => {
    Inline$guarded($listener$19, $event$21, $reader$20);
  });
  Inline$first();
});
export { StringClass$main };
//# sourceMappingURL=StringClass.mjs.map
