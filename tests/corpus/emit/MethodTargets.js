import { List$map } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const MethodTargets$Metre$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const MethodTargets$Metre$$eq = ($x, $y) => $x.a === $y.a;
const MethodTargets$scale = (m$1, factor$2) => {
  const n$3 = m$1.a;
  return { $: "Metre", a: n$3 * factor$2 };
};
const MethodTargets$onOwnType = (m$1) => MethodTargets$scale(m$1, 3);
const MethodTargets$onImportedType = (xs$1) => List$map(xs$1, (x$2) => x$2);
const MethodTargets$onRecord = (h$1) => h$1.run(1);
const MethodTargets$onVariable = ($m$0, x$1, factor$2) => $m$0(x$1, factor$2);
const MethodTargets$main = Node$printLines([]);
export { MethodTargets$Metre$$compare, MethodTargets$Metre$$eq, MethodTargets$main, MethodTargets$scale, MethodTargets$onOwnType, MethodTargets$onImportedType, MethodTargets$onRecord, MethodTargets$onVariable };
//# sourceMappingURL=MethodTargets.mjs.map
