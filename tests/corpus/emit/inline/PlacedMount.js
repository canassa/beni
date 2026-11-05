import { Inline$namedRoot, Inline$root, Inline$own, Inline$client } from "./_platform/Inline.mjs";
const PlacedMount$main = Inline$client(($id$1) => {
  const $root$2 = Inline$root(Inline$namedRoot("app"));
  const $init$3 = {};
  $root$2.insertAdjacentHTML("beforeend", "<main><h1>Hello");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
});
export { PlacedMount$main };
//# sourceMappingURL=PlacedMount.mjs.map
