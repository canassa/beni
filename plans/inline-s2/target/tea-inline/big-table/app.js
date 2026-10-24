import { flush, cancel, schedule } from "./runtime.js";
import { keepSelected } from "./scenario.js";
import { W, section } from "./tables/table.js";
import "./tables/t1.js";

export function start(root) {
  // The page, from its markup like every table.
  root.insertAdjacentHTML("beforeend", "<div data-role=page>");
  const board = root.lastChild;
  // Every table in page order, given its buttons and body (table `tN` is number N, its position
  // from 1: its handle is `views[N]`; `map` skips the hole at 0): its state and its list.
  const views = W.map(([html, table], i) => table(section(board, i, html)));
  schedule(views.map(([, list]) => list));
  flush();

  // The arms of update still reached by a message: external events. They move data, the same for
  // every table; the rows they copy are the message's, not ours to edit.
  function receive(msg) {
    if (msg.type === "snapshot") {
      for (const id in msg.state.tables) {
        const [s, list] = views[id.slice(1)];
        Object.assign(s, structuredClone(msg.state.tables[id]));
        schedule(list);
      }
      return;
    }
    const [s, list] = views[msg.table.slice(1)];
    switch (msg.type) {
      case "serverRows":
        s.rows = structuredClone(msg.rows);
        keepSelected(s);
        s.nextId = s.rows.reduce((max, item) => Math.max(max, item.id + 1), s.nextId);
        schedule(list);
        break;
      case "serverUpdate":
        for (const { id, value } of msg.changes) {
          const item = s.rows.find((x) => x.id === id);
          if (item) {
            item[msg.column] = value;
            schedule(list.get(id)?.[1]);
          }
        }
        break;
      case "serverDelete": {
        const gone = new Set(msg.ids);
        s.rows = s.rows.filter((item) => !gone.has(item.id));
        keepSelected(s);
        schedule(list);
        break;
      }
    }
  }

  function stop() {
    cancel();
    board.remove();
  }

  return { receive, stop };
}
