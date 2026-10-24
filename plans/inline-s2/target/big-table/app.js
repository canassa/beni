import { guard, stopAll, revive } from "./runtime.js";
import { fromList, foldl, member, update, remove, nothing } from "./dict.js";
import { W, section } from "./tables/table.js";
import "./tables/t1.js";

const TESTS = [Number.isSafeInteger, (x) => typeof x === "string", (x) => typeof x === "boolean"];
function decodeRows(shape, raw) {
  if (!Array.isArray(raw)) return;
  const out = [];
  for (const x of raw) {
    if (typeof x !== "object" || x === null || Array.isArray(x)) return;
    const v = {};
    for (const [n, t] of shape) { if (!TESTS[t](x[n])) return; v[n] = x[n]; }
    out.push([v.id, v]);
  }
  return out;
}
const validCell = (shape, c, x) => shape.some(([n, t]) => n === c && n !== "id" && TESTS[t](x));

export function start(root) {
  revive();
  root.insertAdjacentHTML("beforeend", "<div data-role=page>");
  const board = root.lastChild;
  const views = W.map(([html, table], i) => table(section(board, i, html)));
  views.forEach(([, list]) => list());
  function receive(msg) {
    if (msg.type === "snapshot") {
      const next = [];
      for (const id in msg.state.tables) {
        const v = views[id.slice(1)], t = msg.state.tables[id];
        const rows = decodeRows(v[2], t.rows);
        if (!rows || !(t.selected === null || Number.isSafeInteger(t.selected)) || !Number.isSafeInteger(t.nextId) || !Number.isSafeInteger(t.rng)) return;
        next.push([v, rows, t]);
      }
      for (const [[s, list], rows, t] of next) {
        s.rows = fromList(rows); s.selected = t.selected === null ? nothing : { $: 0, a: t.selected }; s.nextId = t.nextId; s.rng = t.rng;
        list();
      }
      return;
    }
    const v = views[msg.table.slice(1)];
    if (!v) return;
    const [s, list] = v, o = s.selected;
    switch (msg.type) {
      case "serverRows": {
        const rows = decodeRows(v[2], msg.rows);
        if (!rows) return;
        s.rows = fromList(rows);
        member(s.rows, s.selected.a) || (s.selected = nothing);
        s.nextId = foldl(s.rows, s.nextId, (k, r, m) => Math.max(m, k + 1));
        list();
        break;
      }
      case "serverUpdate": {
        const c = msg.column;
        if (!Array.isArray(msg.changes) || !msg.changes.every((x) => Number.isSafeInteger(x?.id) && validCell(v[2], c, x.value))) return;
        for (const { id, value } of msg.changes) {
          update(s.rows, id, (m) => (m.$ === 0 && (m.a[c] = value), m)); list.at(id);
        }
        
        break;
      }
      case "serverDelete":
        for (const id of msg.ids) { remove(s.rows, id); list.at(id); }
        member(s.rows, s.selected.a) || (s.selected = nothing);
        
        break;
    }
    o.a != null && list.at(o.a); s.selected.a != null && list.at(s.selected.a);
  }
  function stop() { stopAll(); board.remove(); }
  return { receive: (msg) => guard(receive, msg), stop };
}
