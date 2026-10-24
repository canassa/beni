// The tea-inline runtime for long keyed tables (big-table only; the other scenarios do not
// include it): one row template parsed once, and the keyed row list. Generic, independent of any
// table or scenario; counted as runtime.

import { schedule } from "./runtime.js";

// ---------------------------------------------------------------------------------------------
// Rows

// One row's markup, parsed once: clone it for every row.
export const tpl = (html) => {
  const t = document.createElement("template");
  t.innerHTML = html;
  return t.content.firstChild;
};

// A keyed list of rows (by `item.id`) owning every child of `parent`. `items()` reads the array
// from the model; `build(item)` makes a row once and returns `[node, set, ...]`, `set` being the
// row's binding: it paints the item it is given (or the row's own, when scheduled). The list
// calls it for new rows and for rows whose id came back with another item object; an action that
// edits an item in place schedules its row's `set` itself (`get(id)` finds a row).
//
// The list is itself a binding, for when the array was replaced (create, clear, sort, a filter, a
// server push, a snapshot): rows are reused by id, those whose id left are removed, and one
// forward pass puts the rest in order (a row already in place stays; any other moves before the
// first row not yet placed). When no row is reused the parent is emptied in one go. Actions that
// only add, drop or swap rows in place schedule just that (`add`, `drop`, `swap`); an edit that
// a reconcile in the same flush already made is skipped.
export function rows(parent, items, build) {
  let map = new Map();
  let last;

  const make = (item) => {
    const r = build(item);
    r.item = item;
    r[1](item);
    map.set(item.id, r);
    return r[0];
  };

  const binding = () => {
    const xs = items();
    if (xs === last) return;
    last = xs;
    const old = map;
    map = new Map();
    const nodes = [];
    let kept = 0;
    for (const item of xs) {
      const r = old.get(item.id);
      if (r) {
        kept++;
        old.delete(item.id);
        map.set(item.id, r);
        if (r.item !== item) {
          r.item = item;
          r[1](item);
        }
        nodes.push(r[0]);
      } else nodes.push(make(item));
    }
    if (!kept) {
      const all = new DocumentFragment();
      for (const node of nodes) all.append(node);
      parent.replaceChildren(all);
      return;
    }
    for (const r of old.values()) r[0].remove();
    let at = parent.firstChild;
    for (const node of nodes) node === at ? (at = at.nextSibling) : parent.insertBefore(node, at);
  };

  binding.get = (id) => map.get(id);
  // An action that edited the array in place schedules the matching edit of the DOM. It is
  // dropped when the array was replaced since (a reconcile has the final array in hand then, and
  // an edit of the old one would undo it).
  binding.add = (added) => {
    const xs = items();
    schedule(() => {
      if (items() !== xs) return;
      const all = new DocumentFragment();
      for (const item of added) if (!map.has(item.id)) all.append(make(item));
      parent.append(all);
    });
  };
  binding.drop = (id) => {
    const xs = items();
    schedule(() => {
      if (items() !== xs) return;
      map.get(id)?.[0].remove();
      map.delete(id);
    });
  };
  // The rows of ids `a` and `b` trade places: the array now says `a` goes before `b`, so
  // swap their nodes unless they are in that order already (a reconcile in the flush did it).
  binding.swap = (a, b) => {
    const xs = items();
    schedule(() => {
      const x = map.get(a)?.[0];
      const y = map.get(b)?.[0];
      if (items() === xs && x && y && x.compareDocumentPosition(y) & 2) {
        const after = x.nextSibling;
        y.replaceWith(x);
        parent.insertBefore(y, after);
      }
    });
  };
  return binding;
}
