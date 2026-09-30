import { Basics$append, Basics$add, Basics$modBy } from "./_core/Basics.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { Array$initialize, Array$update, Array$indexedMap, Array$get, Array$set, Array$filter, Array$append, Array$push } from "./_core/Array.mjs";
import { $dup, $drop } from "rc-rt";
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
  return { rc: 1, nextId: $t$2, rows: $t$1, selected: 0 };
};
// research/42 R1 by hand. Model holds an Array, so it is a counted record (O5) with a drop that
// releases its field when the record dies (Perceus's drop, specialised to the type).
const Table$Model$drop = (m) => { if (--m.rc === 0) $drop(m.rows); }; // R1
const Table$updateLabel = (i$1) => ({ $: "UpdateLabel", a: i$1, b: null });
const Table$updateEvery10th = Table$UpdateEvery10th;
const Table$swap = (i$1, j$2) => ({ $: "Swap", a: i$1, b: j$2 });
const Table$remove = (id$1) => ({ $: "Remove", a: id$1, b: null });
const Table$append = (n$1) => ({ $: "Append", a: n$1, b: null });
const Table$addOne = Table$AddOne;
const Table$select = (id$1) => ({ $: "Select", a: id$1, b: null });
const Table$update = (msg$1, model$2) => {
  switch (msg$1.$) {
    case "UpdateLabel":
      {
        const i$3 = msg$1.a;
        // O4: the last use of the owned model takes its field — moved if the model is unique,
        // dup'd (and the model dropped) if not
        const u$ = model$2.rc === 1;
        const rows$ = u$ ? model$2.rows : $dup(model$2.rows);
        if (!u$) Table$Model$drop(model$2); // R1
        return { ...model$2, rc: 1, rows: Array$update(rows$, i$3, (r$4) => ({ ...r$4, label: Basics$append(r$4.label, " !!!") })) };
      }
    case "UpdateEvery10th":
      {
        // indexedMap borrows the rows; the old rows lose their holder when the model is unique
        const rows$ = Array$indexedMap(model$2.rows, (i$5, r$6) => Basics$modBy(i$5, 10) === 0 ? { ...r$6, label: Basics$append(r$6.label, " !!!") } : r$6);
        if (model$2.rc === 1) $drop(model$2.rows); // R1
        else Table$Model$drop(model$2); // R1
        return { ...model$2, rc: 1, rows: rows$ };
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
            const u$ = model$2.rc === 1;
            const rows$ = u$ ? model$2.rows : $dup(model$2.rows);
            if (!u$) Table$Model$drop(model$2); // R1
            return { ...model$2, rc: 1, rows: Array$set(Array$set(rows$, i$7, b$10), j$8, a$9) };
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
        const u$ = model$2.rc === 1;
        const rows$ = u$ ? model$2.rows : $dup(model$2.rows);
        if (!u$) Table$Model$drop(model$2); // R1
        return { ...model$2, rc: 1, rows: Array$filter(rows$, (r$12) => r$12.id !== id$11) };
      }
    case "Append":
      {
        const n$13 = msg$1.a;
        // the lambda uses the model only through a scalar field, so it captures that field and
        // not the model (§3, rule O8); otherwise the capture would dup the model and every
        // Append would copy the rows
        const nextId$ = model$2.nextId;
        const u$ = model$2.rc === 1;
        const rows$ = u$ ? model$2.rows : $dup(model$2.rows);
        if (!u$) Table$Model$drop(model$2); // R1
        const more$ = Array$initialize(n$13, (i$14) => Table$row(Basics$add(nextId$, i$14)));
        const r$ = { ...model$2, rc: 1, rows: Array$append(rows$, more$), nextId: Basics$add(nextId$, n$13) };
        $drop(more$); // R1
        return r$;
      }
    case "AddOne":
      {
        const nextId$ = model$2.nextId;
        const u$ = model$2.rc === 1;
        const rows$ = u$ ? model$2.rows : $dup(model$2.rows);
        if (!u$) Table$Model$drop(model$2); // R1
        return { ...model$2, rc: 1, rows: Array$push(rows$, Table$row(nextId$)), nextId: Basics$add(nextId$, 1) };
      }
    default:
      {
        const id$15 = msg$1.a;
        // the rows move from a unique model to the new one; a shared model's are dup'd
        if (model$2.rc !== 1) {
          $dup(model$2.rows);
          Table$Model$drop(model$2); // R1
        }
        return { ...model$2, rc: 1, selected: id$15 };
      }
  }
};
export { Table$Msg$$compare, Table$Msg$$eq, Table$create, Table$updateLabel, Table$updateEvery10th, Table$swap, Table$remove, Table$append, Table$addOne, Table$select, Table$update };
