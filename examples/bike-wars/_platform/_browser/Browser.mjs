import { Task$onDefect } from "../../_core/Task.mjs";
let Browser$loop = null;
let Browser$setPhase = null;
let Browser$waiters = [];
let Browser$later = [];
let Browser$busy = false;
const Browser$afterRender = () => {
  const resumes$1 = Browser$waiters;
  const work$2 = Browser$later;
  Browser$waiters = [];
  Browser$later = [];
  Browser$busy = true;
  try {
    for (const resume$3 of resumes$1) {
      resume$3(null);
    }
    for (const f$4 of work$2) {
      f$4();
    }
    return null;
  } finally {
    Browser$busy = false;
  }
};
let Browser$nudge = null;
const Browser$skip = [];
let Browser$dispatching = false;
let Browser$inbox = [];
const Browser$drain = (i$1) => {
  while (i$1 < Browser$inbox.length) {
    Browser$inbox[i$1](Browser$inbox[i$1 + 1]);
    i$1 = i$1 + 2;
  }
};
const Browser$host = (p$1, root$2, flushing$3, phase$4, stop$5) => {
  Browser$loop = flushing$3;
  Task$onDefect(() => stop$5());
  Browser$setPhase = phase$4;
  phase$4(Browser$afterRender);
  const send$6 = (msg$13) => {
    root$2.$$root(msg$13);
    return null;
  };
  Browser$nudge = () => send$6(Browser$skip);
  let model$7 = null;
  let started$8 = false;
  let dirty$9 = false;
  let shown$10 = null;
  const self$11 = { after: (f$14) => {
    Browser$later.push(f$14);
    return send$6(Browser$skip);
  }, send: send$6 };
  const apply$12 = (msg$15) => {
    dirty$9 = true;
    model$7 = p$1.update(self$11, msg$15, model$7);
    return null;
  };
  return { init: () => null, update: (msg$16) => {
    if (msg$16 === Browser$skip) {
      return null;
    } else {
      if (Browser$dispatching) {
        Browser$inbox.push(apply$12, msg$16);
        return null;
      } else {
        Browser$dispatching = true;
        try {
          apply$12(msg$16);
          Browser$drain(0);
          return null;
        } finally {
          Browser$inbox = [];
          Browser$dispatching = false;
        }
      }
    }
  }, view: () => {
    if (!started$8) {
      started$8 = true;
      model$7 = p$1.settle(self$11, p$1.init(self$11));
      shown$10 = p$1.view(model$7);
      return shown$10;
    } else {
      if (!dirty$9) {
        return shown$10;
      } else {
        dirty$9 = false;
        Browser$busy = true;
        try {
          model$7 = p$1.settle(self$11, model$7);
          shown$10 = p$1.view(model$7);
          return shown$10;
        } finally {
          Browser$busy = false;
        }
      }
    }
  } };
};
const Browser$hosted = (p$1) => [{ h: (root$2, flushing$3, phase$4, stop$5) => Browser$host(p$1, root$2, flushing$3, phase$4, stop$5), n: null }];
export { Browser$hosted };
//# sourceMappingURL=Browser.mjs.map
