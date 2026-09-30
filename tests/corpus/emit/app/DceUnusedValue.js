import { String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const DceUnusedValue$helper = (n$1) => n$1 + 1;
const DceUnusedValue$used = (n$1) => String$fromInt(DceUnusedValue$helper(n$1));
const DceUnusedValue$main = Node$printLines({ $: 1, a: DceUnusedValue$used(1), b: { $: 0, a: null, b: null } });
export { DceUnusedValue$main, DceUnusedValue$used };
