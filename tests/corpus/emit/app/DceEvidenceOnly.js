import { String$length, String$fromInt } from "./core/String.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const DceEvidenceOnly$byLength = (t$1) => {
  const text$2 = t$1.a;
  return String$length(text$2);
};
const DceEvidenceOnly$eq = (a$1, b$2) => DceEvidenceOnly$byLength(a$1) === DceEvidenceOnly$byLength(b$2);
const DceEvidenceOnly$anyEqual = ($m$0, x$1, y$2) => $m$0(x$1, y$2);
const DceEvidenceOnly$main = Node$printLines({ $: 1, a: String$fromInt(DceEvidenceOnly$anyEqual(DceEvidenceOnly$eq, { $: "Tagged", a: "a" }, { $: "Tagged", a: "b" }) ? 1 : 0), b: { $: 0, a: null, b: null } });
export { DceEvidenceOnly$main, DceEvidenceOnly$eq, DceEvidenceOnly$byLength, DceEvidenceOnly$anyEqual };
