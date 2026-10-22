import { Helpers$init, Helpers$pair, Helpers$lambda, Helpers$named, Helpers$first } from "./Helpers.mjs";
import { Probe$one } from "./_platform/Probe.mjs";
import { Node$printLines } from "./_platform/_node/Node.mjs";
import { String$fromInt } from "./_core/String.mjs";
const CrossModuleUnit$result = (() => {
  const $t$1 = Helpers$init();
  const $t$2 = Helpers$pair(7);
  const $t$3 = Helpers$lambda();
  return { lambda: $t$3, model: $t$1, pair: $t$2 };
})();
const CrossModuleUnit$reference = Helpers$init;
const CrossModuleUnit$kept = (() => {
  const $t$1 = Helpers$named(null);
  const $t$2 = Helpers$first(null, 9);
  return { first: $t$2, named: $t$1 };
})();
const CrossModuleUnit$foreignResult = Probe$one(null);
const CrossModuleUnit$main = Node$printLines([String$fromInt(CrossModuleUnit$result.model.cups), String$fromInt(CrossModuleUnit$result.pair), String$fromInt(CrossModuleUnit$result.lambda), String$fromInt(CrossModuleUnit$reference(null).cups), String$fromInt(CrossModuleUnit$kept.first), String$fromInt(CrossModuleUnit$foreignResult)]);
export { CrossModuleUnit$main, CrossModuleUnit$result, CrossModuleUnit$reference, CrossModuleUnit$kept, CrossModuleUnit$foreignResult };
//# sourceMappingURL=CrossModuleUnit.mjs.map
