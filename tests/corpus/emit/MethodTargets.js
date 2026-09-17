import { Basics$mul } from "./core/Basics.mjs";
import { List$map } from "./core/List.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const MethodTargets$Metre$$eq = ($x, $y) => $x.a === $y.a;
const MethodTargets$scale = (m$1, factor$2) => {
  let $t$1;
  const n$3 = m$1.a;
  $t$1 = { $: "Metre", a: Basics$mul(n$3, factor$2) };
  return $t$1;
};
const MethodTargets$onOwnType = (m$1) => MethodTargets$scale(m$1, 3);
const MethodTargets$onImportedType = (xs$1) => List$map(xs$1, (x$2) => x$2);
const MethodTargets$onRecord = (h$1) => h$1.run(1);
const MethodTargets$onVariable = ($m$0, x$1, factor$2) => $m$0(x$1, factor$2);
const MethodTargets$main = Node$printLines({ $: 0, a: null, b: null });
export { MethodTargets$Metre$$eq, MethodTargets$main, MethodTargets$scale, MethodTargets$onOwnType, MethodTargets$onImportedType, MethodTargets$onRecord, MethodTargets$onVariable };
