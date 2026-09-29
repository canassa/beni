// P2, research 29 §7.1: the hand-written prototype of what a template
// compiler could emit for The Elm Architecture. One immutable model, a pure
// `update` returning a new model with structural sharing, the view re-run
// from the root on every message, each hole comparing its own input by
// `===`, and the list hole reconciling row instances by key.
//
// Reconstructed for the end-to-end measurement: research 29's scratchpad did
// not survive, so this file is §7.1's two listings verbatim (`makeRow`,
// `updateRow`, `makeListHole`) with the parts §4.3 describes and does not
// print written back in: the model and `update` over a JavaScript array,
// synchronous dispatch, one listener per button and one delegated listener
// on the `<tbody>`, and `reconcileArrays` from dom-expressions with its
// ownership tags removed.

const adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]; // prettier-ignore
const colors = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]; // prettier-ignore
const nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]; // prettier-ignore

const random = (max) => Math.round(Math.random() * 1000) % max;

// ---- The model half: what a beni `update` over an array would be ----------

const empty = { rows: [], selected: 0, nextId: 1 };

const buildData = (nextId, count) => {
  const data = new Array(count);
  for (let i = 0; i < count; i++) {
    data[i] = {
      id: nextId + i,
      label: `${adjectives[random(adjectives.length)]} ${colors[random(colors.length)]} ${nouns[random(nouns.length)]}`,
    };
  }
  return data;
};

const update = (msg, m) => {
  switch (msg.$) {
    case "Run":
      return { ...m, rows: buildData(m.nextId, 1000), nextId: m.nextId + 1000 };
    case "RunLots":
      return { ...m, rows: buildData(m.nextId, 10000), nextId: m.nextId + 10000 };
    case "Add":
      return { ...m, rows: m.rows.concat(buildData(m.nextId, 1000)), nextId: m.nextId + 1000 };
    case "Update": {
      const rows = m.rows.slice();
      for (let i = 0; i < rows.length; i += 10) rows[i] = { ...rows[i], label: rows[i].label + " !!!" };
      return { ...m, rows };
    }
    case "Clear":
      return { ...m, rows: [] };
    case "Swap": {
      if (m.rows.length <= 998) return m;
      const rows = m.rows.slice();
      const t = rows[1];
      rows[1] = rows[998];
      rows[998] = t;
      return { ...m, rows };
    }
    case "Select":
      return { ...m, selected: msg.id };
    case "Remove":
      return { ...m, rows: m.rows.filter((r) => r.id !== msg.id) };
  }
  return m;
};

// ---- The view half: §7.1 --------------------------------------------------

const ROW_TPL = document.createElement("template");
ROW_TPL.innerHTML =
  '<tr><td class="col-md-1"> </td><td class="col-md-4"><a> </a></td>' +
  '<td class="col-md-1"><a><span class="glyphicon glyphicon-remove" aria-hidden="true"></span></a></td>' +
  '<td class="col-md-6"></td></tr>';
const ROW_PROTO = ROW_TPL.content.firstChild;

function makeRow(row, selected) {
  const el = ROW_PROTO.cloneNode(true);
  const tds = el.firstChild;
  const idT = tds.firstChild;
  const lbT = tds.nextSibling.firstChild.firstChild;
  idT.nodeValue = row.id;
  lbT.nodeValue = row.label;
  if (row.id === selected) el.className = "danger";
  el.__id = row.id;
  return { el, row, sel: row.id === selected, idT, lbT };
}

function updateRow(inst, row, selected) {
  const sel = row.id === selected;
  if (inst.row !== row) {
    if (inst.row.label !== row.label) inst.lbT.nodeValue = row.label;
    if (inst.row.id !== row.id) inst.idT.nodeValue = row.id;
    inst.row = row;
  }
  if (inst.sel !== sel) {
    inst.el.className = sel ? "danger" : "";
    inst.sel = sel;
  }
}

// dom-expressions' reconcileArrays (udomdiff) without `$$SLOT`: this page
// owns the whole `<tbody>`, so every node in `a` is live.
function reconcileArrays(parentNode, a, b) {
  const bLength = b.length;
  let aEnd = a.length;
  let bEnd = bLength;
  let aStart = 0;
  let bStart = 0;
  const after = a[aEnd - 1].nextSibling;
  let map = null;
  while (aStart < aEnd || bStart < bEnd) {
    if (a[aStart] === b[bStart]) {
      aStart++;
      bStart++;
      continue;
    }
    while (a[aEnd - 1] === b[bEnd - 1]) {
      aEnd--;
      bEnd--;
    }
    if (aEnd === aStart) {
      const node = bEnd < bLength ? (bStart ? b[bStart - 1].nextSibling : b[bEnd - bStart]) : after;
      while (bStart < bEnd) parentNode.insertBefore(b[bStart++], node);
    } else if (bEnd === bStart) {
      while (aStart < aEnd) {
        if (!map || !map.has(a[aStart])) a[aStart].remove();
        aStart++;
      }
    } else if (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]) {
      const node = a[--aEnd].nextSibling;
      parentNode.insertBefore(b[bStart++], a[aStart++].nextSibling);
      parentNode.insertBefore(b[--bEnd], node);
      a[aEnd] = b[bEnd];
    } else {
      if (!map) {
        map = new Map();
        let i = bStart;
        while (i < bEnd) map.set(b[i], i++);
      }
      const index = map.get(a[aStart]);
      if (index != null) {
        if (bStart < index && index < bEnd) {
          let i = aStart;
          let sequence = 1;
          let t;
          while (++i < aEnd && i < bEnd) {
            if ((t = map.get(a[i])) == null || t !== index + sequence) break;
            sequence++;
          }
          if (sequence > index - bStart) {
            const node = a[aStart];
            while (bStart < index) parentNode.insertBefore(b[bStart++], node);
          } else parentNode.replaceChild(b[bStart++], a[aStart++]);
        } else aStart++;
      } else a[aStart++].remove();
    }
  }
}

function makeListHole(tbody) {
  let insts = new Map();
  let nodes = [];
  return function run(rows, selected) {
    const n = rows.length;
    if (n === 0) {
      if (nodes.length) {
        tbody.textContent = "";
        insts = new Map();
        nodes = [];
      }
      return;
    }
    const next = new Array(n);
    const nextInsts = new Map();
    let moved = nodes.length !== n;
    for (let i = 0; i < n; i++) {
      const row = rows[i];
      let inst = insts.get(row.id);
      if (inst === undefined) {
        inst = makeRow(row, selected);
        moved = true;
      } else {
        updateRow(inst, row, selected);
        insts.delete(row.id);
      }
      nextInsts.set(row.id, inst);
      next[i] = inst.el;
      if (!moved && nodes[i] !== inst.el) moved = true;
    }
    if (moved) {
      if (nodes.length === 0) {
        const f = document.createDocumentFragment();
        for (let i = 0; i < n; i++) f.appendChild(next[i]);
        tbody.appendChild(f);
      } else reconcileArrays(tbody, nodes, next);
    }
    insts = nextInsts;
    nodes = next;
  };
}

// ---- The loop: dispatch, the buttons, the delegated table listener --------

const tbody = document.getElementById("tbody");
const listHole = makeListHole(tbody);
let model = empty;
const dispatch = (msg) => {
  model = update(msg, model);
  listHole(model.rows, model.selected);
};

for (const [id, tag] of [["run", "Run"], ["runlots", "RunLots"], ["add", "Add"], ["update", "Update"], ["clear", "Clear"], ["swaprows", "Swap"]]) {
  const msg = { $: tag };
  document.getElementById(id).addEventListener("click", (e) => {
    e.stopPropagation();
    dispatch(msg);
  });
}

tbody.addEventListener("click", (e) => {
  const a = e.target.closest("a");
  if (a === null) return;
  e.preventDefault();
  const tr = a.closest("tr");
  const id = tr.__id;
  if (a.parentNode.classList.contains("col-md-4")) dispatch({ $: "Select", id });
  else dispatch({ $: "Remove", id });
});
