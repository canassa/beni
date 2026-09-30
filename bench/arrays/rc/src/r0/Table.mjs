import { Basics$append, Basics$add, Basics$modBy } from "./_core/Basics.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { Array$initialize, Array$update, Array$indexedMap, Array$get, Array$setU, Array$filter, Array$appendU, Array$pushU } from "./_core/Array.mjs";
const Table$AddOne = { $: "AddOne", a: null, b: null };
const Table$UpdateEvery10th = { $: "UpdateEvery10th", a: null, b: null };
const Table$Msg$$order = { UpdateLabel: 0, UpdateEvery10th: 1, Swap: 2, Remove: 3, Append: 4, AddOne: 5, Select: 6 };
const Table$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return Table$Msg$$order[$x.$] < Table$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "UpdateLabel":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    case "UpdateEvery10th":
      return "EQ";
    case "Swap":
      const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return $x.b < $y.b ? "LT" : $x.b > $y.b ? "GT" : "EQ";
    case "Remove":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    case "Append":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    case "AddOne":
      return "EQ";
    default:
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
  }
};
const Table$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "UpdateLabel":
      return $x.a === $y.a;
    case "UpdateEvery10th":
      return true;
    case "Swap":
      return $x.a === $y.a && $x.b === $y.b;
    case "Remove":
      return $x.a === $y.a;
    case "Append":
      return $x.a === $y.a;
    case "AddOne":
      return true;
    default:
      return $x.a === $y.a;
  }
};
const Table$row = (id$1) => ({ id: id$1, label: Basics$append("row ", String$fromInt(id$1)) });
const Table$create = (n$1) => {
  const $t$1 = Array$initialize(n$1, (i$2) => Table$row(Basics$add(i$2, 1)));
  const $t$2 = Basics$add(n$1, 1);
  return { nextId: $t$2, rows: $t$1, selected: 0 };
};
const Table$updateLabel = (i$1) => ({ $: "UpdateLabel", a: i$1, b: null });
const Table$updateEvery10th = Table$UpdateEvery10th;
const Table$swap = (i$1, j$2) => ({ $: "Swap", a: i$1, b: j$2 });
const Table$remove = (id$1) => ({ $: "Remove", a: id$1, b: null });
const Table$append = (n$1) => ({ $: "Append", a: n$1, b: null });
const Table$addOne = Table$AddOne;
const Table$select = (id$1) => ({ $: "Select", a: id$1, b: null });
// research/42 R0 by hand. Interface summary (S2): `model.rows` is CONSUMED-UNIQUE (UpdateLabel,
// Swap, Append and AddOne write it; it is dead after), and the result's rows are unique when the
// argument's were (S4), so a runtime that hands the model over keeps it unique by induction.
const Table$update = (msg$1, model$2) => {
  switch (msg$1.$) {
    case "UpdateLabel":
      {
        const i$3 = msg$1.a;
        return { ...model$2, rows: Array$update(model$2.rows, i$3, (r$4) => ({ ...r$4, label: Basics$append(r$4.label, " !!!") })) };
      }
    case "UpdateEvery10th":
      {
        return { ...model$2, rows: Array$indexedMap(model$2.rows, (i$5, r$6) => Basics$modBy(i$5, 10) === 0 ? { ...r$6, label: Basics$append(r$6.label, " !!!") } : r$6) };
      }
    case "Swap":
      {
        const i$7 = msg$1.a;
        const j$8 = msg$1.b;
        const $t$3 = Array$get(model$2.rows, i$7);
        if ($t$3.$ === "Just") {
          const a$9 = $t$3.a;
          const $t$4 = Array$get(model$2.rows, j$8);
          if ($t$4.$ === "Just") {
            const b$10 = $t$4.a;
            return { ...model$2, rows: Array$setU(Array$setU(model$2.rows, i$7, b$10), j$8, a$9) };
          } else {
            return model$2;
          }
        } else {
          return model$2;
        }
      }
    case "Remove":
      {
        const id$11 = msg$1.a;
        return { ...model$2, rows: Array$filter(model$2.rows, (r$12) => r$12.id !== id$11) };
      }
    case "Append":
      {
        const n$13 = msg$1.a;
        return { ...model$2, rows: Array$appendU(model$2.rows, Array$initialize(n$13, (i$14) => Table$row(Basics$add(model$2.nextId, i$14)))), nextId: Basics$add(model$2.nextId, n$13) };
      }
    case "AddOne":
      {
        return { ...model$2, rows: Array$pushU(model$2.rows, Table$row(model$2.nextId)), nextId: Basics$add(model$2.nextId, 1) };
      }
    default:
      {
        const id$15 = msg$1.a;
        return { ...model$2, selected: id$15 };
      }
  }
};
export { Table$Msg$$compare, Table$Msg$$eq, Table$create, Table$updateLabel, Table$updateEvery10th, Table$swap, Table$remove, Table$append, Table$addOne, Table$select, Table$update };
