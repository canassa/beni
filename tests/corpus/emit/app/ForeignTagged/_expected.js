import { Ghost$message } from "./Ghost.mjs";
import { Node$print } from "./_platform/_node/Node.mjs";
import { Carrier$carry } from "./_platform/Carrier.mjs";
const ForeignTagged$choose = () => ({ $: "Kept", a: null });
const ForeignTagged$show = (choice$1) => choice$1.$ === "Kept" ? "kept" : Ghost$message(null);
const ForeignTagged$main = Node$print(ForeignTagged$show(Carrier$carry(ForeignTagged$choose)));
export { ForeignTagged$main };
//# sourceMappingURL=ForeignTagged.mjs.map
