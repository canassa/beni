import { Basics$mul } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const EvidenceValue$scale = (m$1, factor$2) => {
  let $t$1;
  const n$3 = m$1.a;
  $t$1 = { $: "Metre", a: Basics$mul(n$3, factor$2) };
  return $t$1;
};
const EvidenceValue$twice = ($m$0, x$1, factor$2) => $m$0($m$0(x$1, factor$2), factor$2);
const EvidenceValue$apply = (f$1, m$2) => f$1(m$2, 2);
const EvidenceValue$grow = (m$1) => EvidenceValue$apply(($p$2, $p$3) => EvidenceValue$twice(EvidenceValue$scale, $p$2, $p$3), m$1);
const EvidenceValue$bound = ($p$4, $p$5) => EvidenceValue$twice(EvidenceValue$scale, $p$4, $p$5);
const EvidenceValue$main = Node$printLines({ $: 0, a: null, b: null });
export { EvidenceValue$main, EvidenceValue$scale, EvidenceValue$grow, EvidenceValue$bound };
