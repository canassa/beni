import { Node$printLines } from "./_platform/Node.mjs";
const EvidenceParameters$Metre$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const EvidenceParameters$Metre$$eq = ($x, $y) => $x.a === $y.a;
const EvidenceParameters$scale = (m$1, factor$2) => {
  const n$3 = m$1.a;
  return { $: "Metre", a: n$3 * factor$2 };
};
const EvidenceParameters$inner = ($m$0, x$1, factor$2) => $m$0(x$1, factor$2);
const EvidenceParameters$middle = ($m$0, x$1, factor$2) => EvidenceParameters$inner($m$0, x$1, factor$2);
const EvidenceParameters$outer = ($m$0, x$1, factor$2) => EvidenceParameters$middle($m$0, x$1, factor$2);
const EvidenceParameters$grow = (m$1) => EvidenceParameters$outer(EvidenceParameters$scale, m$1, 3);
const EvidenceParameters$main = Node$printLines([]);
export { EvidenceParameters$Metre$$compare, EvidenceParameters$Metre$$eq, EvidenceParameters$main, EvidenceParameters$scale, EvidenceParameters$grow };
