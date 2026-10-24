import { el, text, on, when, list, schedule } from "../runtime.js";
import { W, nextId } from "./widget.js";

// Widget w1: its markup, and its code over the markup's elements.
W.push(["<h2>Studio planner o97g</h2><fieldset><footer><p></p><button data-role=boostSheets>Add 3</button><button data-role=restoreSheets>Start over</button><small>Code o97g</small></footer></fieldset><button data-role=rotateTone></button><strong></strong><div><small></small><button data-role=setLapsTo4>= 4</button></div><button data-role=shrinkLaps>-2</button><div><output></output><div><button data-role=zeroLaps>Reset</button><button data-role=quickAddFiles>+ Reminder</button></div><button data-role=clearFiles>Clear all</button><section><ol></ol><small></small><p>Everything here updates as soon as you act.", (E, s, G) => {
  // The bindings, grouped by the field they read.
  G.push(
    [() => text(E[2], `Sheets: ${s.sheets}`), () => text(E[9], (s.sheets > 3) ? "Plenty" : "Some"), () => when(E[14], s.sheets >= 9)],
    [() => text(E[6], `Tone: ${s.tone}`), () => text(E[7], s.tone), () => when(E[18], s.tone == "Final")],
    [() => text(E[13], s.laps)],
    [list(E[19], () => s.files, (item) => {
      const node = el("li", null, { "data-key": item.id, "data-role": "filesItem" });
      const label = el("span", node);
      const set = (next) => { item = next; text(label, item.text); };
      on(el("button", node, { "data-role": "removeFromFiles" }, "Delete"), () => {
        const at = s.files.findIndex((x) => x.id === item.id);
        if (at < 0) return;
        s.files.splice(at, 1);
        G[3][0].drop(item.id);
        schedule(G[3]);
      });
      return [node, set];
    }), () => text(E[20], `Total: ${s.files.length}`)],
  );

  // The arms of update, as actions.
  on(E[3], () => {
    s.sheets = Math.min(51, s.sheets + 3);
    schedule(G[0]);
  });
  on(E[4], () => {
    s.sheets = 11;
    schedule(G[0]);
  });
  on(E[6], () => {
    s.tone = s.tone == "Final" ? "Draft" : s.tone == "Draft" ? "Review" : "Final";
    schedule(G[1]);
  });
  on(E[10], () => {
    s.laps = 4;
    schedule(G[2]);
  });
  on(E[11], () => {
    s.laps = Math.max(-10, s.laps - 2);
    schedule(G[2]);
  });
  on(E[15], () => {
    s.laps = 12;
    schedule(G[2]);
  });
  on(E[16], () => {
    const item = { id: nextId(s.files), text: "Reminder" };
    s.files.push(item);
    G[3][0].add(item);
    schedule(G[3]);
  });
  on(E[17], () => {
    s.files = [];
    schedule(G[3]);
  });
}]);
