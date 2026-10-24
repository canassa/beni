import { text, prop, on, schedule } from "../runtime.js";
import { rows, tpl } from "../rows.js";
import { state, next, pick } from "../scenario.js";
import { W } from "./table.js";

// Table t1: its markup, and its code over the markup's buttons and body (E), returning its
// state and its list.
W.push(["<h2>Rows amgi</h2><div><button data-role=run>Create 1,000 rows</button><button data-role=runlots>Create 10,000 rows</button><button data-role=add>Append 1,000 rows</button><button data-role=update>Update every 10th row</button><button data-role=clear>Clear</button><button data-role=swaprows>Swap Rows</button></div><table><tbody>", (E) => {
  const s = state(91397855);
  const labelWords0 = ["pretty","large","big","small","tall","short","long","handsome","plain","quaint","clean","elegant","easy","angry","crazy","helpful","mushy","odd","unsightly","adorable","important","inexpensive","cheap","expensive","fancy"];
  const labelWords1 = ["red","yellow","blue","green","pink","brown","purple","brown","white","black","orange"];
  const labelWords2 = ["table","chair","house","bbq","desk","car","pony","cookie","sandwich","burger","pizza","mouse","keyboard"];

  // The row builder: one draw per random cell in column order, then the id.
  const make = (n) => {
    let r = s.rng;
    const out = [];
    while (n--) out.push({ label: `${pick(r = next(r), labelWords0)} ${pick(r = next(r), labelWords1)} ${pick(r = next(r), labelWords2)}`, id: s.nextId++ });
    s.rng = r;
    return out;
  };

  // A row: cloned from the template; its binding `set` paints the row's item.
  const row = tpl("<tr data-role=row><td><td><a data-role=select></a><td><a data-role=remove><span aria-hidden=true>×</span></a><td>");
  const L = rows(E[6], () => s.rows, (item) => {
    const tr = row.cloneNode(true);
    const E = tr.querySelectorAll("*");
    tr.setAttribute("data-key", item.id);
    E[0].textContent = item.id;
    const mark = () => prop(tr, s.selected === item.id ? "danger" : "", "className");
    const set = (fresh = item) => {
      item = fresh;
      text(E[2], item.label);
      mark();
    };
    on(E[2], () => {
      if (!s.rows.some((x) => x.id === item.id)) return;
      const was = s.selected;
      s.selected = item.id;
      schedule(L.get(was)?.[2], mark);
    });
    on(E[4], () => {
      const at = s.rows.findIndex((x) => x.id === item.id);
      if (at < 0) return;
      s.rows.splice(at, 1);
      if (s.selected === item.id) s.selected = null;
      L.drop(item.id);
    });
    return [tr, set, mark];
  });

  // The arms of update, as actions.
  on(E[0], () => {
    s.rows = make(1000);
    s.selected = null;
    schedule(L);
  });
  on(E[1], () => {
    s.rows = make(10000);
    s.selected = null;
    schedule(L);
  });
  on(E[2], () => {
    const added = make(1000);
    s.rows.push(...added);
    L.add(added);
  });
  on(E[3], () => {
    for (let i = 0; i < s.rows.length; i += 10) {
      const item = s.rows[i];
      item.label += " !!!";
      schedule(L.get(item.id)?.[1]);
    }
  });
  on(E[4], () => {
    s.rows = [];
    s.selected = null;
    schedule(L);
  });
  on(E[5], () => {
    if (s.rows.length > 998) {
      const a = s.rows[1];
      const b = s.rows[998];
      s.rows[1] = b;
      s.rows[998] = a;
      L.swap(b.id, a.id);
    }
  });

  return [s, L];
}]);
