import { Basics$mul } from "./_core/Basics.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const EvidenceValue$Metre$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const EvidenceValue$Metre$$eq = ($x, $y) => $x.a === $y.a;
const EvidenceValue$scale = (m$1, factor$2) => {
  const n$3 = m$1.a;
  return { $: "Metre", a: Basics$mul(n$3, factor$2) };
};
const EvidenceValue$twice = ($m$0, x$1, factor$2) => $m$0($m$0(x$1, factor$2), factor$2);
const EvidenceValue$apply = (f$1, m$2) => f$1(m$2, 2);
const EvidenceValue$grow = (m$1) => EvidenceValue$apply(($p$1, $p$2) => EvidenceValue$twice(EvidenceValue$scale, $p$1, $p$2), m$1);
const EvidenceValue$bound = ($p$3, $p$4) => EvidenceValue$twice(EvidenceValue$scale, $p$3, $p$4);
const EvidenceValue$main = Node$printLines({ $: 0, a: null, b: null });
export { EvidenceValue$Metre$$compare, EvidenceValue$Metre$$eq, EvidenceValue$main, EvidenceValue$scale, EvidenceValue$grow, EvidenceValue$bound };
