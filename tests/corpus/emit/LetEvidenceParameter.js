import { listEq as _derived$listEq } from "./_core/_derived.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const LetEvidenceParameter$pairEq = ($m$0, x$1, y$2) => {
  function inner$3($l10$0, a$4, b$5) {
    return $l10$0(a$4, b$5);
  }
  return inner$3($m$0, x$1, y$2) && inner$3(($p$1, $p$2, $p$3) => _derived$listEq($m$0, $p$1, $p$2, $p$3), { $: 1, a: x$1, b: { $: 0, a: null, b: null } }, { $: 1, a: y$2, b: { $: 0, a: null, b: null } });
};
const LetEvidenceParameter$main = Node$printLines({ $: 0, a: null, b: null });
export { LetEvidenceParameter$main, LetEvidenceParameter$pairEq };
