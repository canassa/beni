import { Node$printLines } from "./_platform/Node.mjs";
const NullaryConstant$Maybe$Nothing = { $: "Nothing", a: null };
const NullaryConstant$Run = { $: "Run", a: null };
const NullaryConstant$Msg$$order = { Run: 0, Stop: 1, Add: 2 };
const NullaryConstant$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return NullaryConstant$Msg$$order[$x.$] < NullaryConstant$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Run":
      return "EQ";
    case "Stop":
      return "EQ";
    default:
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
  }
};
const NullaryConstant$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Run":
      return true;
    case "Stop":
      return true;
    default:
      return $x.a === $y.a;
  }
};
const NullaryConstant$idle = NullaryConstant$Run;
const NullaryConstant$button = (label$1) => ({ label: label$1, msg: NullaryConstant$Run });
const NullaryConstant$both = (b$1) => b$1 ? { a: NullaryConstant$Run, b: { $: "Add", a: 1 } } : { a: NullaryConstant$Run, b: NullaryConstant$Run };
const NullaryConstant$none = (n$1) => n$1 > 0 ? { $: "Just", a: n$1 } : NullaryConstant$Maybe$Nothing;
const NullaryConstant$isRun = (m$1) => m$1.$ === "Run" ? true : false;
const NullaryConstant$order = "LT";
const NullaryConstant$main = Node$printLines([]);
export { NullaryConstant$Msg$$compare, NullaryConstant$Msg$$eq, NullaryConstant$main, NullaryConstant$idle, NullaryConstant$button, NullaryConstant$both, NullaryConstant$none, NullaryConstant$isRun, NullaryConstant$order };
//# sourceMappingURL=NullaryConstant.mjs.map
