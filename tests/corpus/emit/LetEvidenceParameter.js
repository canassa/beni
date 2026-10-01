import { listEq as _derived$listEq } from "./_core/_derived.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const LetEvidenceParameter$pairEq = ($m$0, x$1, y$2) => {
  function inner$3($l10$0, a$4, b$5) {
    return $l10$0(a$4, b$5);
  }
  return inner$3($m$0, x$1, y$2) && inner$3(($p$1, $p$2, $p$3) => _derived$listEq($m$0, $p$1, $p$2, $p$3), [x$1], [y$2]);
};
const LetEvidenceParameter$main = Node$printLines([]);
export { LetEvidenceParameter$main, LetEvidenceParameter$pairEq };
//# sourceMappingURL=LetEvidenceParameter.mjs.map
