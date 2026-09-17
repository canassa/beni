import { Basics$eq } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const DerivedEqList$eq$r$x = ($m$0, $x, $y) => $m$0($x.x, $y.x);
const DerivedEqList$sameInts = (a$1, b$2) => Basics$eq(a$1, b$2);
const DerivedEqList$sameRows = (a$1, b$2) => Basics$eq(a$1, b$2);
const DerivedEqList$main = Node$printLines({ $: 0, a: null, b: null });
export { DerivedEqList$main, DerivedEqList$sameInts, DerivedEqList$sameRows };
