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
const DceCtorPattern$main = Node$printLines({ $: 1, a: DceCtorPattern$describe(DceCtorPattern$Red), b: { $: 1, a: DceCtorPattern$describe(DceCtorPattern$Amber), b: { $: 1, a: DceCtorPattern$describe({ $: "Go", a: 3 }), b: { $: 0, a: null, b: null } } } });
export { DceCtorPattern$main, DceCtorPattern$describe };
