import { Basics$append } from "../../_core/Basics.mjs";
import { Task$cleansUp, Task$shutdown, Task$onTurn } from "../../_core/Task.mjs";
const Rt$head = (s$1) => {
  if (s$1.u === null || s$1.u.length === 0) {
    return s$1.i === null ? s$1.m : Rt$first(s$1.i);
  } else {
    return Rt$first(s$1.u[0]);
  }
};
const Rt$first = (i$1) => i$1.s === null ? Rt$head(i$1.q) : i$1.s;
const Rt$tail = (s$1) => {
  if (s$1.m === null) {
    return s$1.u === null || s$1.u.length === 0 ? Rt$last(s$1.i) : Rt$last(s$1.u[s$1.u.length - 1]);
  } else {
    return s$1.m;
  }
};
const Rt$last = (i$1) => i$1.e === null ? Rt$tail(i$1.q) : i$1.e;
const Rt$putRun = (parent$1, n$2, end$3, before$4) => {
  for (;;) {
    const next$5 = n$2.nextSibling;
    parent$1.insertBefore(n$2, before$4);
    if (n$2 === end$3) {
      return null;
    } else {
      n$2 = next$5;
    }
  }
};
const Rt$put = (parent$1, i$2, before$3) => Rt$putRun(parent$1, Rt$first(i$2), Rt$last(i$2), before$3);
const Rt$dropRun = (n$1, end$2) => {
  for (;;) {
    const next$3 = n$1.nextSibling;
    n$1.remove();
    if (n$1 === end$2) {
      return null;
    } else {
      n$1 = next$3;
    }
  }
};
const Rt$drop = (i$1) => Rt$dropRun(Rt$first(i$1), Rt$last(i$1));
const Rt$swap = (old$1, i$2) => {
  const f$3 = Rt$first(old$1);
  Rt$put(f$3.parentNode, i$2, f$3);
  return Rt$drop(old$1);
};
const Rt$gather = (from$1, into$2) => {
  while (from$1.firstChild !== null) {
    into$2.appendChild(from$1.firstChild);
  }
};
const Rt$template = (html$1, flags$2) => {
  let node$3 = null;
  return () => {
    if (node$3 === null) {
      const document$4 = globalThis.document;
      const t$5 = document$4.createElement("template");
      t$5.innerHTML = html$1;
      node$3 = t$5.content;
      if ((flags$2 & 2) !== 0) {
        node$3 = node$3.firstChild;
      }
      if ((flags$2 & 4) !== 0) {
        if ((flags$2 & 2) !== 0) {
          const f$6 = document$4.createDocumentFragment();
          Rt$gather(node$3, f$6);
          node$3 = f$6;
        }
      } else {
        node$3 = node$3.firstChild;
      }
    }
    return (flags$2 & 1) !== 0 ? globalThis.document.importNode(node$3, true) : node$3.cloneNode(true);
  };
};
const Rt$slot = (parent$1, marker$2, cx$3) => ({ b: null, cx: cx$3, d: false, i: null, k: 0, l: false, m: marker$2, p: parent$1, r: null, u: null, w: false, x: null, y: null, z: null });
const Rt$parentOf = (s$1) => s$1.p === null ? s$1.m.parentNode : s$1.p;
const Rt$unit = (b$1, cx$2) => {
  const i$3 = b$1.t.m(b$1.v, cx$2);
  i$3.t = b$1.t;
  i$3.b = b$1;
  return i$3;
};
const Rt$patch = (i$1, b$2, cx$3) => {
  if (b$2 === i$1.b) {
    if (b$2.t.l && i$1.l) {
      b$2.t.p(i$1, b$2.v);
    }
    return i$1;
  } else {
    if (b$2.t === i$1.t) {
      b$2.t.p(i$1, b$2.v);
      i$1.b = b$2;
      return i$1;
    } else {
      const n$4 = Rt$unit(b$2, cx$3);
      Rt$swap(i$1, n$4);
      return n$4;
    }
  }
};
const Rt$again = (i$1) => i$1.t.p(i$1, i$1.b.v);
const Rt$restate = (s$1) => {
  const w$2 = s$1.w;
  if (w$2) {
    w$2(s$1, 0);
  }
  if (s$1.l) {
    const i$3 = s$1.i;
    Rt$again(i$3);
    s$1.l = i$3.l;
    return null;
  } else {
    return null;
  }
};
const Rt$restateRows = (s$1, stamp$2) => {
  const r$3 = s$1.r;
  let any$4 = false;
  for (const i$5 of s$1.u) {
    if (i$5.l) {
      if (i$5.rs !== stamp$2) {
        if (i$5.t === undefined) {
          r$3(i$5, i$5.x, i$5.y);
        } else {
          Rt$again(i$5);
        }
      }
      if (i$5.l) {
        any$4 = true;
      }
    }
  }
  s$1.w = any$4 ? Rt$restateRows : false;
  return null;
};
const Rt$held = (s$1, i$2) => {
  if (i$2.t.l) {
    s$1.l = i$2.l;
    return null;
  } else {
    return null;
  }
};
const Rt$childHtml = (s$1, b$2) => {
  if (s$1.i === null) {
    const i$3 = Rt$unit(b$2, s$1.cx);
    Rt$put(Rt$parentOf(s$1), i$3, s$1.m);
    s$1.i = i$3;
    return Rt$held(s$1, i$3);
  } else {
    s$1.i = Rt$patch(s$1.i, b$2, s$1.cx);
    return Rt$held(s$1, s$1.i);
  }
};
let Rt$queued = [];
let Rt$scheduled = false;
let Rt$phase = null;
let Rt$turning = false;
let Rt$flushing = false;
let Rt$dead = false;
let Rt$screenLine = null;
let Rt$screenReport = null;
const Rt$crashScreen = () => {
  const document$1 = globalThis.document;
  const screen$2 = document$1.createElement("div");
  screen$2.setAttribute("style", "position:fixed;inset:0;z-index:2147483647;overflow:auto;margin:0;padding:24px;background:#fff;color:#a00;font:14px/1.5 monospace;white-space:pre-wrap");
  screen$2.textContent = "This program has stopped.\n\nSomething it ran threw an exception, so its state can no longer be trusted and nothing more of it runs. The exception is below, and in the console with its stack.\n\n";
  document$1.body.appendChild(screen$2);
  const add$3 = (more$6) => {
    const shown$7 = screen$2.textContent;
    screen$2.textContent = Basics$append(shown$7, more$6);
    return null;
  };
  let seen$4 = 0;
  const report$5 = (event$8) => {
    const error$9 = event$8.error;
    const message$10 = globalThis.String(error$9 == null ? event$8.message : error$9);
    const n$11 = seen$4;
    seen$4 = n$11 + 1;
    let $t$1;
    if (n$11 === 0) {
      $t$1 = message$10;
    } else {
      $t$1 = n$11 === 1 ? Basics$append("\n\nWhile stopping, cleanup also threw:\n", message$10) : Basics$append("\n", message$10);
    }
    return add$3($t$1);
  };
  Rt$screenLine = add$3;
  Rt$screenReport = report$5;
  globalThis.window.addEventListener("error", report$5, { once: !Task$cleansUp(null) });
};
const Rt$deadline = 1000;
const Rt$stopped = (cut$1) => {
  const line$2 = "Cleanups cut short while stopping:";
  if (cut$1 !== 0) {
    globalThis.console.warn(line$2, cut$1);
  }
  if (cut$1 !== 0) {
    Rt$screenLine(Basics$append(`

${line$2} `, globalThis.String(cut$1)));
  }
  return globalThis.window.removeEventListener("error", Rt$screenReport);
};
const Rt$stop = () => {
  if (!Rt$dead) {
    Rt$crashScreen();
  }
  if (Rt$phase !== null) {
    Task$shutdown(Rt$deadline, Rt$stopped);
  }
  Rt$dead = true;
  return null;
};
const Rt$flush = () => {
  if (Rt$dead) {
    return null;
  } else {
    let ok$1 = false;
    try {
      Rt$scheduled = false;
      Rt$flushing = true;
      const renders$2 = Rt$queued;
      Rt$queued = [];
      for (const render$3 of renders$2) {
        render$3();
      }
      if (!(Rt$phase == null)) {
        Rt$phase();
      }
      ok$1 = true;
      return null;
    } finally {
      Rt$flushing = false;
      if (!ok$1) {
        Rt$stop();
      }
    }
  }
};
const Rt$turn = (trusted$1, f$2) => {
  if (trusted$1 && !(Rt$turning || Rt$flushing)) {
    let ok$3 = false;
    Rt$turning = true;
    try {
      f$2(null);
      ok$3 = true;
    } finally {
      Rt$turning = false;
      if (!ok$3) {
        Rt$stop();
      }
    }
    return Rt$scheduled ? Rt$flush() : null;
  } else {
    return f$2(null);
  }
};
let Rt$afterRender = null;
const Rt$renderEnded = (root$1) => Rt$afterRender == null ? null : Rt$afterRender(root$1);
const Rt$microtask = () => Rt$scheduled ? Rt$flush() : null;
const Rt$mount = (program$1, root$2) => {
  const s$3 = Rt$slot(root$2, null, null);
  let model$4 = program$1.init();
  let waiting$5 = false;
  const render$6 = () => {
    waiting$5 = false;
    Rt$childHtml(s$3, program$1.view(model$4));
    return Rt$renderEnded(root$2);
  };
  root$2.$$root = (msg$7) => {
    if (Rt$dead) {
      return null;
    } else {
      if (!waiting$5) {
        waiting$5 = true;
        Rt$queued.push(render$6);
        if (!Rt$scheduled) {
          Rt$scheduled = true;
          if (!Rt$turning) {
            globalThis.queueMicrotask(() => Rt$microtask());
          }
        }
      }
      model$4 = program$1.update(msg$7, model$4);
      return null;
    }
  };
  Rt$childHtml(s$3, program$1.view(model$4));
  return Rt$renderEnded(root$2);
};
const Rt$setPhase = (f$1) => {
  Rt$phase = f$1;
  return Rt$scheduled;
};
const Rt$startOne = (m$1) => {
  const document$2 = globalThis.document;
  const root$3 = m$1.n === null ? document$2.body : document$2.getElementById(m$1.n);
  if (root$3 === null || !(root$3.$$root === undefined)) {
    const id$4 = m$1.n;
    const $t$3 = globalThis.Error;
    let $t$2;
    if (root$3 === null) {
      $t$2 = `no element has the id "${id$4}" to mount a program at`;
    } else {
      $t$2 = m$1.n === null ? "the page's body already holds a program" : `the element "${id$4}" already holds a program`;
    }
    throw new $t$3($t$2);
  }
  if (m$1.h === undefined) {
    return Rt$mount(m$1.a, root$3);
  } else {
    Task$onTurn((f$5) => Rt$turn(true, f$5));
    return Rt$mount(m$1.h(root$3, Rt$flush, (f$6) => Rt$setPhase(f$6), Rt$stop), root$3);
  }
};
const Rt$run = (program$1) => {
  let ok$2 = false;
  try {
    for (const m$3 of program$1) {
      Rt$startOne(m$3);
    }
    ok$2 = true;
    return null;
  } finally {
    if (!ok$2) {
      Rt$stop();
    }
  }
};
const Rt$elements = (list$1) => globalThis.Array.isArray(list$1) ? list$1 : list$1.$plain();
const Rt$childrenFrom = (s$1, u$2, a$3, k$4) => {
  while (k$4 < a$3.length) {
    if (k$4 < u$2.length) {
      u$2[k$4] = Rt$patch(u$2[k$4], a$3[k$4], s$1.cx);
    } else {
      const i$5 = Rt$unit(a$3[k$4], s$1.cx);
      Rt$put(Rt$parentOf(s$1), i$5, s$1.m);
      u$2.push(i$5);
    }
    if (u$2[k$4].t.l && u$2[k$4].l) {
      s$1.w = Rt$restateRows;
    }
    k$4 = k$4 + 1;
  }
};
const Rt$dropPast = (u$1, k$2) => {
  while (u$1.length > k$2) {
    Rt$drop(u$1.pop());
  }
  return null;
};
const Rt$childList = (s$1, list$2) => {
  if (list$2 === s$1.b) {
    return Rt$restate(s$1);
  } else {
    s$1.b = list$2;
    s$1.w = false;
    if (s$1.u === null) {
      s$1.u = [];
    }
    const u$3 = s$1.u;
    const a$4 = Rt$elements(list$2);
    Rt$childrenFrom(s$1, u$3, a$4, 0);
    return Rt$dropPast(u$3, a$4.length);
  }
};
const Rt$textKind = { m: (v$1) => {
  const n$2 = globalThis.document.createTextNode(v$1);
  return { d: v$1, e: n$2, q: null, s: n$2 };
}, p: (i$3, v$4) => {
  if (v$4 === i$3.d) {
    return null;
  } else {
    i$3.d = v$4;
    i$3.s.data = v$4;
    return null;
  }
} };
const Rt$text = (s$1) => ({ t: Rt$textKind, v: s$1 });
export { Rt$first, Rt$last, Rt$put, Rt$drop, Rt$swap, Rt$template, Rt$slot, Rt$parentOf, Rt$unit, Rt$patch, Rt$restate, Rt$childHtml, Rt$flush, Rt$run, Rt$elements, Rt$childList, Rt$text };
//# sourceMappingURL=Rt.mjs.map
