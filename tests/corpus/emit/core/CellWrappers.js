import { Js$optNone } from "./_core/Js.mjs";
const CellWrappers$RecordWrapper$$compare = ($x, $y) => CellWrappers$compare$r$value(CellWrappers$compare$prim, $x.a, $y.a);
const CellWrappers$RecordWrapper$$eq = ($x, $y) => CellWrappers$eq$r$value(CellWrappers$eq$prim, $x.a, $y.a);
const CellWrappers$compare$prim = ($x, $y) => $x < $y ? "LT" : $x > $y ? "GT" : "EQ";
const CellWrappers$compare$r$value = ($m$0, $x, $y) => $m$0($x.value, $y.value);
const CellWrappers$eq$prim = ($x, $y) => $x === $y;
const CellWrappers$eq$r$value = ($m$0, $x, $y) => $m$0($x.value, $y.value);
const CellWrappers$instance = (value$1) => ({ child: Js$optNone, value: value$1 });
const CellWrappers$slot = (value$1) => ({ shown: value$1 });
const CellWrappers$read = ($p$1) => {
  const cell$1 = $p$1;
  return cell$1.value;
};
const CellWrappers$aliased = (value$1) => ({ value: value$1 });
const CellWrappers$ref = (value$1) => ({ $: "RefWrapper", a: { v: value$1 } });
const CellWrappers$record = (value$1) => ({ $: "RecordWrapper", a: { value: value$1 } });
const CellWrappers$severalFields = (value$1) => ({ $: "TwoFields", a: { value: value$1 }, b: value$1 });
const CellWrappers$severalConstructors = (value$1) => ({ $: "First", a: { value: value$1 } });
export { CellWrappers$RecordWrapper$$compare, CellWrappers$RecordWrapper$$eq, CellWrappers$instance, CellWrappers$slot, CellWrappers$read, CellWrappers$aliased, CellWrappers$ref, CellWrappers$record, CellWrappers$severalFields, CellWrappers$severalConstructors };
//# sourceMappingURL=CellWrappers.mjs.map
