import { Node$printLines } from "./_platform/Node.mjs";
const DceCtorPattern$Amber = { $: "Amber", a: null };
const DceCtorPattern$Red = { $: "Red", a: null };
const DceCtorPattern$describe = (s$1) => {
  switch (s$1.$) {
    case "Red":
      {
        return "stop";
      }
    case "Amber":
      {
        return "wait";
      }
    default:
      {
        return "go";
      }
  }
};
const DceCtorPattern$main = Node$printLines([DceCtorPattern$describe(DceCtorPattern$Red), DceCtorPattern$describe(DceCtorPattern$Amber), DceCtorPattern$describe({ $: "Go", a: 3 })]);
export { DceCtorPattern$main, DceCtorPattern$describe };
//# sourceMappingURL=DceCtorPattern.mjs.map
