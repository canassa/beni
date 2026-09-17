import { Basics$mul } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const EvidenceParameters$Metre$$eq = ($x, $y) => $x.a === $y.a;
const EvidenceParameters$scale = (m$1, factor$2) => {
  let $t$1;
  const n$3 = m$1.a;
  $t$1 = { $: "Metre", a: Basics$mul(n$3, factor$2) };
  return $t$1;
};
const EvidenceParameters$inner = ($m$0, x$1, factor$2) => $m$0(x$1, factor$2);
const EvidenceParameters$middle = ($m$0, x$1, factor$2) => EvidenceParameters$inner($m$0, x$1, factor$2);
const EvidenceParameters$outer = ($m$0, x$1, factor$2) => EvidenceParameters$middle($m$0, x$1, factor$2);
const EvidenceParameters$grow = (m$1) => EvidenceParameters$outer(EvidenceParameters$scale, m$1, 3);
const EvidenceParameters$main = Node$printLines({ $: 0, a: null, b: null });
export { EvidenceParameters$Metre$$eq, EvidenceParameters$main, EvidenceParameters$scale, EvidenceParameters$grow };
