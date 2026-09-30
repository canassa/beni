import { Array$map, Array$setU, Array$update } from "./_core/Array.mjs";
import { Basics$append } from "./_core/Basics.mjs";
import { String$fromFloat } from "./_core/String.mjs";
const Interop$lines = (items$1) => Array$map(items$1, (it$2) => ({ id: it$2.id, text: Basics$append(it$2.name, Basics$append(" ", String$fromFloat(it$2.price))) }));
const Interop$prices = (items$1) => Array$map(items$1, (it$2) => it$2.price);
// research/42 R0 by hand: reprice and rename CONSUME their array uniquely (S2); callers copy (S3)
const Interop$reprice = (ps$1, i$2) => Array$setU(ps$1, i$2, 0.5);
const Interop$rename = (ls$1, i$2) => Array$update(ls$1, i$2, (l$3) => ({ ...l$3, text: "renamed" }));
export { Interop$lines, Interop$prices, Interop$reprice, Interop$rename };
