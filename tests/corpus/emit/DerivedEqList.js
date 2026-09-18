import { List$eq } from "./core/List.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const DerivedEqList$eq$prim = ($x, $y) => $x === $y;
const DerivedEqList$eq$r$x = ($m$0, $x, $y) => $m$0($x.x, $y.x);
const DerivedEqList$sameInts = (a$1, b$2) => List$eq(DerivedEqList$eq$prim, a$1, b$2);
const DerivedEqList$sameRows = (a$1, b$2) => List$eq(($p$1, $p$2) => DerivedEqList$eq$r$x(DerivedEqList$eq$prim, $p$1, $p$2), a$1, b$2);
const DerivedEqList$main = Node$printLines({ $: 0, a: null, b: null });
export { DerivedEqList$main, DerivedEqList$sameInts, DerivedEqList$sameRows };
