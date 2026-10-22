import { Ghost$message } from "./Ghost.mjs";
import { Node$print } from "./_platform/_node/Node.mjs";
import { Carrier$carry } from "./_platform/Carrier.mjs";
const ForeignCallback$choose = () => "Kept";
const ForeignCallback$show = (choice$1) => choice$1 === "Kept" ? "kept" : Ghost$message();
const ForeignCallback$main = Node$print(ForeignCallback$show(Carrier$carry(ForeignCallback$choose)));
export { ForeignCallback$main };
//# sourceMappingURL=ForeignCallback.mjs.map
