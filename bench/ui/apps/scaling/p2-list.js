// P2's keyed list hole (apps/p2/bench.js, research 29 §7.1), generic over
// the row: `make(item)` returns an instance `{ el, item, … }` and
// `patch(inst, item)` brings one up to date. An instance whose item is the
// same object is not patched, which is the row skip beni's `For` makes.

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

function makeListHole(parent, make, patch) {
  let insts = new Map();
  let nodes = [];
  let last = null;
  return function run(items) {
    if (items === last) return;
    last = items;
    const n = items.length;
    if (n === 0) {
      if (nodes.length) {
        parent.textContent = "";
        insts = new Map();
        nodes = [];
      }
      return;
    }
    const next = new Array(n);
    const nextInsts = new Map();
    let moved = nodes.length !== n;
    for (let i = 0; i < n; i++) {
      const item = items[i];
      let inst = insts.get(item.id);
      if (inst === undefined) {
        inst = make(item);
        moved = true;
      } else {
        if (inst.item !== item) {
          patch(inst, item);
          inst.item = item;
        }
        insts.delete(item.id);
      }
      nextInsts.set(item.id, inst);
      next[i] = inst.el;
      if (!moved && nodes[i] !== inst.el) moved = true;
    }
    if (moved) {
      if (nodes.length === 0) {
        const f = document.createDocumentFragment();
        for (let i = 0; i < n; i++) f.appendChild(next[i]);
        parent.appendChild(f);
      } else reconcileArrays(parent, nodes, next);
    }
    insts = nextInsts;
    nodes = next;
  };
}
