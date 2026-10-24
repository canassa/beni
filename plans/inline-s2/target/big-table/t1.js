import { text, prop, on } from "../runtime.js";
import { list, tpl } from "../rows.js";
import { just, nothing, empty, size, member, keyAt, insert, remove, swap, update } from "../dict.js";
import { state, next, pick } from "../scenario.js";
import { W } from "./table.js";

W.push(["<h2>Rows amgi</h2><div><button data-role=run>Create 1,000 rows</button><button data-role=runlots>Create 10,000 rows</button><button data-role=add>Append 1,000 rows</button><button data-role=update>Update every 10th row</button><button data-role=clear>Clear</button><button data-role=swaprows>Swap Rows</button></div><table><tbody>", (E) => {
  const s = state(91397855);
  const labelWords0 = ["pretty","large","big","small","tall","short","long","handsome","plain","quaint","clean","elegant","easy","angry","crazy","helpful","mushy","odd","unsightly","adorable","important","inexpensive","cheap","expensive","fancy"];
  const labelWords1 = ["red","yellow","blue","green","pink","brown","purple","brown","white","black","orange"];
  const labelWords2 = ["table","chair","house","bbq","desk","car","pony","cookie","sandwich","burger","pizza","mouse","keyboard"];

  const make = (d, n, l) => {
    let r = s.rng;
    while (n--) { const v = { label: `${pick(r = next(r), labelWords0)} ${pick(r = next(r), labelWords1)} ${pick(r = next(r), labelWords2)}` }; v.id = s.nextId++; insert(d, v.id, v); l && l.at(v.id); }
    s.rng = r;
    return d;
  };

  const row = tpl("<tr data-role=row><td><td><a data-role=select></a><td><a data-role=remove><span aria-hidden=true>×</span></a><td>");
  const L = list(E[6], () => s.rows, (k, item) => {
    const tr = row.cloneNode(true);
    const E = tr.querySelectorAll("*");
    tr.setAttribute("data-key", k);
    E[0].textContent = k;
    on(E[2], () => {
      if (!member(s.rows, k)) return;
      const o = s.selected;
      s.selected = just(k);
      o.a != null && L.at(o.a); s.selected.a != null && L.at(s.selected.a);
    });
    on(E[4], () => {
      const o = s.selected;
      remove(s.rows, k);
      if (s.selected.a === k) s.selected = nothing;
      L.at(k);
      o.a != null && L.at(o.a); s.selected.a != null && L.at(s.selected.a);
    });
    return [tr, (v) => { item = v; text(E[2], item.label); prop(tr, s.selected.a === k ? "danger" : "", "className"); }];
  });

  on(E[0], () => {
    const o = s.selected;
    s.rows = make(empty(), 1000);
    s.selected = nothing;
    L();
    o.a != null && L.at(o.a); s.selected.a != null && L.at(s.selected.a);
  });
  on(E[1], () => {
    const o = s.selected;
    s.rows = make(empty(), 10000);
    s.selected = nothing;
    L();
    o.a != null && L.at(o.a); s.selected.a != null && L.at(s.selected.a);
  });
  on(E[2], () => {
    make(s.rows, 1000, L);
  });
  on(E[3], () => {
    for (let i = 0; i < size(s.rows); i += 10) { const k = keyAt(s.rows, i).a; update(s.rows, k, (m) => (m.$ === 0 && (m.a.label += " !!!"), m)); L.at(k); }
  });
  on(E[4], () => {
    const o = s.selected;
    s.rows = empty();
    s.selected = nothing;
    L();
    o.a != null && L.at(o.a); s.selected.a != null && L.at(s.selected.a);
  });
  on(E[5], () => {
    if (size(s.rows) > 998) {
      const a = keyAt(s.rows, 1).a, b = keyAt(s.rows, 998).a;
      swap(s.rows, a, b);
      L.swap(a, b);
    }
  });

  const shape = [["id",0],["label",1]];
  return [s, L, shape];
}]);
