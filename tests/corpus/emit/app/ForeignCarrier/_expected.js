import { Carrier$carry } from "./_platform/Carrier.mjs";
import { Node$print } from "./_platform/_node/Node.mjs";
const ForeignCarrier$choose = () => "Kept";
const ForeignCarrier$show = (choice$1) => "kept";
const ForeignCarrier$main = (() => {
  Carrier$carry(ForeignCarrier$choose);
  return Node$print(ForeignCarrier$show(ForeignCarrier$choose()));
})();
export { ForeignCarrier$main };
//# sourceMappingURL=ForeignCarrier.mjs.map
