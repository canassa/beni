import { Inline$root, Inline$own } from "./_platform/Inline.mjs";
const PlacedMount$main = ($id$1) => {
  const $root$2 = Inline$root("app");
  const $init$3 = {};
  $root$2.insertAdjacentHTML("beforeend", "<main><h1>Hello");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
};
export { PlacedMount$main };
//# sourceMappingURL=PlacedMount.mjs.map
