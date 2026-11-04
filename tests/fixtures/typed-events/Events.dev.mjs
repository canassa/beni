import { Js$optNone } from "../../_core/Js.mjs";
import { Browser$Host$Event$preventDefault, Browser$Host$Event$stopPropagation, Browser$Host$Event$isTrusted, Browser$Host$Event$kind } from "../../_core/Browser/Host/Event.mjs";
import { Browser$Host$Set$make, Browser$Host$Set$has, Browser$Host$Set$add, Browser$Host$Set$size, Browser$Host$Set$each, Browser$Host$Set$clear } from "../../_core/Browser/Host/Set.mjs";
import { Browser$Host$Document$listen } from "../../_core/Browser/Host/Document.mjs";
import { Browser$Host$Events$listen, Browser$Host$Events$capture } from "../../_core/Browser/Host/Events.mjs";
import { Html$Runtime$control, Html$Runtime$propertyName, Html$Runtime$propertySet, Html$Runtime$propertyGet, Html$Runtime$controlCell, Html$Runtime$propertyImmutable } from "../../_platform/_html/Html/Runtime.mjs";
import { Basics$min } from "../../_core/Basics.mjs";
import { Browser$Host$Array$eachView } from "../../_core/Browser/Host/Array.mjs";
import { Browser$Host$Timers$start } from "../../_core/Browser/Host/Timers.mjs";
import { Browser$Host$Window$listen } from "../../_core/Browser/Host/Window.mjs";
const Rt$Events$through = (p$1, c$2, msg$3) => {
  while (p$1.contextPresent(c$2)) {
    const $t$1 = p$1.contextParent(c$2);
    msg$3 = p$1.contextApply(c$2, msg$3);
    c$2 = $t$1;
  }
  return msg$3;
};
const Rt$Events$mountAbove = (p$1, at$2) => {
  let $t$3;
  if (at$2 !== Js$optNone) {
    let $t$2;
    if (p$1.hasRoot(at$2)) {
      $t$2 = at$2;
    } else {
      const $t$1 = at$2.parentNode;
      $t$2 = Rt$Events$mountAbove(p$1, $t$1 === null ? Js$optNone : $t$1);
    }
    $t$3 = $t$2;
  } else {
    $t$3 = Js$optNone;
  }
  return $t$3;
};
const Rt$Events$fire = (p$1, node$2, event$3, key$4, payload$5, flags$6) => {
  if (p$1.dead(null)) {
    return null;
  } else {
    if ((flags$6 & 1) !== 0) {
      Browser$Host$Event$preventDefault(event$3);
    }
    let ok$7 = false;
    try {
      const msg$8 = Rt$Events$through(p$1, p$1.nodeContext(node$2), p$1.eventPayload(node$2, event$3, key$4, payload$5));
      const $t$1 = node$2.parentNode;
      const $t$2 = Rt$Events$mountAbove(p$1, $t$1 === null ? Js$optNone : $t$1);
      if ($t$2 !== Js$optNone) {
        p$1.sendRoot($t$2, msg$8);
      }
      ok$7 = true;
    } finally {
      if (!ok$7) {
        p$1.stop(null);
      }
    }
    return (flags$6 & 2) !== 0 ? Browser$Host$Event$stopPropagation(event$3) : null;
  }
};
const Rt$Events$bubble = (p$1, event$2, key$3, flagged$4, payload$5, at$6, current$7) => {
  let $t$7;
  if (current$7 !== Js$optNone) {
    let $t$1;
    if (p$1.hasHandler(current$7, key$3) && !!!current$7.disabled) {
      const flags$9 = p$1.handlerFlags(current$7, flagged$4);
      const $t$2 = at$6.v;
      let $t$3;
      if ($t$2 !== Js$optNone) {
        $t$3 = null;
      } else {
        globalThis.Object.defineProperty(event$2, "currentTarget", { configurable: true, get: () => at$6.v === Js$optNone ? null : at$6.v });
        $t$3 = null;
      }
      at$6.v = current$7;
      Rt$Events$fire(p$1, current$7, event$2, key$3, payload$5, flags$9);
      let $t$5;
      if ((flags$9 & 2) !== 0) {
        $t$5 = null;
      } else {
        const $t$4 = current$7.parentNode;
        $t$5 = Rt$Events$bubble(p$1, event$2, key$3, flagged$4, payload$5, at$6, $t$4 === null ? Js$optNone : $t$4);
      }
      $t$1 = $t$5;
    } else {
      const $t$6 = current$7.parentNode;
      $t$1 = Rt$Events$bubble(p$1, event$2, key$3, flagged$4, payload$5, at$6, $t$6 === null ? Js$optNone : $t$6);
    }
    $t$7 = $t$1;
  } else {
    $t$7 = null;
  }
  return $t$7;
};
const Rt$Events$delegated = (p$1, key$2, flagged$3, payload$4, event$5) => p$1.turn(Browser$Host$Event$isTrusted(event$5), () => {
  const at$6 = { v: Js$optNone };
  try {
    const $t$1 = event$5.target;
    return Rt$Events$bubble(p$1, event$5, key$2, flagged$3, payload$4, at$6, $t$1 instanceof globalThis.Node ? $t$1 : Js$optNone);
  } finally {
    const $t$2 = at$6.v;
    let $t$3;
    if ($t$2 !== Js$optNone) {
      globalThis.Reflect.deleteProperty(event$5, "currentTarget");
      $t$3 = null;
    } else {
      $t$3 = null;
    }
  }
});
const Rt$Events$registered = Browser$Host$Set$make(null);
const Rt$Events$delegate = (p$1, name$2) => {
  if (Browser$Host$Set$has(Rt$Events$registered, name$2)) {
    return null;
  } else {
    Browser$Host$Set$add(Rt$Events$registered, name$2);
    const key$3 = `$$${name$2}`;
    const flagged$4 = `${key$3}F`;
    const payload$5 = `${key$3}X`;
    Browser$Host$Document$listen(name$2, (event$6) => Rt$Events$delegated(p$1, key$3, flagged$4, payload$5, event$6));
    return null;
  }
};
const Rt$Events$listen = (p$1, node$2, name$3, flags$4) => {
  const key$5 = `$$${name$3}`;
  const payload$6 = `${key$5}X`;
  Browser$Host$Events$listen(node$2, name$3, (event$7) => p$1.hasHandler(node$2, key$5) ? p$1.turn(Browser$Host$Event$isTrusted(event$7), () => Rt$Events$fire(p$1, node$2, event$7, key$5, payload$6, flags$4)) : null);
  return null;
};
let Rt$Events$stored = Js$optNone;
let Rt$Events$afterRender = Js$optNone;
const Rt$Events$entry = (d$1, v$2) => Html$Runtime$control({ d: d$1, next: Js$optNone, v: v$2 });
let Rt$Events$watching = false;
const Rt$Events$touched = Browser$Host$Set$make(null);
const Rt$Events$units = (s$1) => s$1.length;
const Rt$Events$writeProp = (node$1, d$2, v$3) => {
  if (Html$Runtime$propertyName(d$2) !== "value") {
    return Html$Runtime$propertySet(d$2, node$1, v$3);
  } else {
    if (Html$Runtime$propertyGet(d$2, node$1) === v$3) {
      return null;
    } else {
      const $t$1 = node$1.selectionStart;
      const $t$2 = $t$1 === undefined || $t$1 === null ? Js$optNone : $t$1;
      let $t$8;
      if ($t$2 !== Js$optNone) {
        let $t$3;
        if (node$1 === globalThis.document.activeElement) {
          const $t$4 = node$1.selectionEnd;
          const $t$5 = $t$4 === undefined || $t$4 === null ? Js$optNone : $t$4;
          const end$5 = $t$5 !== Js$optNone ? $t$5 : $t$2;
          const direction$6 = node$1.selectionDirection;
          Html$Runtime$propertySet(d$2, node$1, v$3);
          const length$7 = Rt$Events$units(node$1.value);
          const $t$6 = Basics$min($t$2, length$7);
          const $t$7 = Basics$min(end$5, length$7);
          node$1.setSelectionRange($t$6, $t$7, direction$6);
          $t$3 = null;
        } else {
          $t$3 = Html$Runtime$propertySet(d$2, node$1, v$3);
        }
        $t$8 = $t$3;
      } else {
        $t$8 = Html$Runtime$propertySet(d$2, node$1, v$3);
      }
      return $t$8;
    }
  }
};
const Rt$Events$restore = (node$1, at$2) => {
  const fields$3 = Html$Runtime$controlCell(at$2);
  const d$4 = fields$3.d;
  const v$5 = fields$3.v;
  if (!Html$Runtime$propertyImmutable(d$4)) {
    Rt$Events$writeProp(node$1, d$4, v$5);
  } else {
    if (!(Html$Runtime$propertyGet(d$4, node$1) === v$5)) {
      Rt$Events$writeProp(node$1, d$4, v$5);
    }
  }
  const $t$1 = fields$3.next;
  return $t$1 !== Js$optNone ? Rt$Events$restore(node$1, $t$1) : null;
};
const Rt$Events$putBack = (p$1, node$2) => {
  const $t$1 = p$1.controls(node$2);
  return $t$1 !== Js$optNone ? Rt$Events$restore(node$2, $t$1) : null;
};
const Rt$Events$putBackOne = (node$1) => {
  const $t$1 = Rt$Events$stored;
  return $t$1 !== Js$optNone ? Rt$Events$putBack($t$1, node$1) : null;
};
const Rt$Events$putBackMarked = (root$1) => {
  if (Browser$Host$Set$size(Rt$Events$touched) !== 0) {
    Browser$Host$Set$each(Rt$Events$touched, Rt$Events$putBackOne);
    Browser$Host$Set$clear(Rt$Events$touched);
  }
  const $t$1 = root$1.$$e;
  const $t$2 = $t$1 === undefined ? Js$optNone : $t$1;
  let $t$4;
  if ($t$2 !== Js$optNone) {
    let $t$3;
    if (Browser$Host$Set$size($t$2) !== 0) {
      Browser$Host$Set$each($t$2, Rt$Events$putBackOne);
      $t$3 = Browser$Host$Set$clear($t$2);
    } else {
      $t$3 = null;
    }
    $t$4 = $t$3;
  } else {
    $t$4 = null;
  }
  return $t$4;
};
const Rt$Events$affected = (node$1, f$2) => {
  f$2(node$1);
  const tag$3 = node$1.localName || "";
  if (tag$3 === "select") {
    return Browser$Host$Array$eachView(node$1.options, f$2);
  } else {
    if (tag$3 === "input" && (node$1.type || "") === "radio" && (node$1.name || "") !== "") {
      const $t$1 = node$1.name || "";
      return Browser$Host$Array$eachView(globalThis.document.getElementsByName($t$1), f$2);
    } else {
      return null;
    }
  }
};
const Rt$Events$markEdit = (node$1) => {
  const $t$1 = Rt$Events$stored;
  let $t$10;
  if ($t$1 !== Js$optNone) {
    const $t$2 = $t$1.controls(node$1);
    let $t$9;
    if ($t$2 !== Js$optNone) {
      const $t$3 = node$1.parentNode;
      const $t$4 = Rt$Events$mountAbove($t$1, $t$3 === null ? Js$optNone : $t$3);
      let $t$8;
      if ($t$4 !== Js$optNone) {
        const $t$5 = $t$4.$$e;
        const $t$6 = $t$5 === undefined ? Js$optNone : $t$5;
        let $t$7;
        if ($t$6 !== Js$optNone) {
          $t$7 = Browser$Host$Set$add($t$6, node$1);
        } else {
          const marked$4 = Browser$Host$Set$make(null);
          Browser$Host$Set$add(marked$4, node$1);
          $t$4.$$e = marked$4;
          $t$7 = null;
        }
        $t$8 = $t$7;
      } else {
        $t$8 = null;
      }
      $t$9 = $t$8;
    } else {
      $t$9 = null;
    }
    $t$10 = $t$9;
  } else {
    $t$10 = null;
  }
  return $t$10;
};
const Rt$Events$heldBack = Browser$Host$Set$make(null);
const Rt$Events$putBackHeld = () => {
  const $t$1 = Rt$Events$stored;
  if ($t$1 !== Js$optNone) {
    if (!$t$1.dead(null)) {
      Browser$Host$Set$each(Rt$Events$heldBack, Rt$Events$putBackOne);
    }
  }
  return Browser$Host$Set$clear(Rt$Events$heldBack);
};
const Rt$Events$holdEdit = (node$1) => {
  if (Browser$Host$Set$size(Rt$Events$heldBack) === 0) {
    Browser$Host$Timers$start(Rt$Events$putBackHeld, 0);
  }
  return Browser$Host$Set$add(Rt$Events$heldBack, node$1);
};
const Rt$Events$markAndHold = (node$1) => {
  Rt$Events$markEdit(node$1);
  return Rt$Events$holdEdit(node$1);
};
const Rt$Events$edits = (event$1) => {
  const $t$1 = event$1.target;
  const $t$2 = $t$1 instanceof globalThis.Node ? $t$1 : Js$optNone;
  let $t$5;
  if ($t$2 !== Js$optNone) {
    const name$3 = Browser$Host$Event$kind(event$1);
    let $t$3;
    if (name$3 === "reset") {
      $t$3 = ($t$2.localName || "") === "form" ? Browser$Host$Array$eachView($t$2.elements, (node$4) => Rt$Events$affected(node$4, Rt$Events$markAndHold)) : null;
    } else {
      let $t$4;
      if (name$3 !== "click") {
        $t$4 = Rt$Events$affected($t$2, Rt$Events$markEdit);
      } else {
        const kind$5 = $t$2.type || "";
        $t$4 = kind$5 === "checkbox" || kind$5 === "radio" ? Rt$Events$affected($t$2, Rt$Events$markAndHold) : null;
      }
      $t$3 = $t$4;
    }
    $t$5 = $t$3;
  } else {
    $t$5 = null;
  }
  return $t$5;
};
const Rt$Events$pageShown = ($p$1) => {
  const $t$2 = Rt$Events$stored;
  return $t$2 !== Js$optNone ? !$t$2.dead(null) ? Browser$Host$Array$eachView(globalThis.document.querySelectorAll("input,select,textarea,option"), Rt$Events$putBackOne) : null : null;
};
const Rt$Events$watch = (p$1) => {
  if (!Rt$Events$watching) {
    Rt$Events$watching = true;
    Rt$Events$stored = p$1;
    Rt$Events$afterRender = Rt$Events$putBackMarked;
    const page$2 = globalThis.document;
    Browser$Host$Events$capture(page$2, "input", Rt$Events$edits);
    Browser$Host$Events$capture(page$2, "change", Rt$Events$edits);
    Browser$Host$Events$capture(page$2, "click", Rt$Events$edits);
    Browser$Host$Events$capture(page$2, "reset", Rt$Events$edits);
    Browser$Host$Window$listen("pageshow", Rt$Events$pageShown);
  }
};
const Rt$Events$apply = (node$1, d$2, v$3, immutable$4, changed$5) => {
  if (!immutable$4) {
    return Rt$Events$writeProp(node$1, d$2, v$3);
  } else {
    return changed$5 && !(Html$Runtime$propertyGet(d$2, node$1) === v$3) ? Rt$Events$writeProp(node$1, d$2, v$3) : null;
  }
};
const Rt$Events$place = (node$1, at$2, d$3, v$4, immutable$5) => {
  const fields$6 = Html$Runtime$controlCell(at$2);
  if (Html$Runtime$propertyName(fields$6.d) === Html$Runtime$propertyName(d$3)) {
    const previous$8 = fields$6.v;
    fields$6.d = d$3;
    fields$6.v = v$4;
    return Rt$Events$apply(node$1, d$3, v$4, immutable$5, !(previous$8 === v$4));
  } else {
    const $t$1 = fields$6.next;
    let $t$2;
    if ($t$1 !== Js$optNone) {
      $t$2 = Rt$Events$place(node$1, $t$1, d$3, v$4, immutable$5);
    } else {
      fields$6.next = Rt$Events$entry(d$3, v$4);
      $t$2 = Rt$Events$apply(node$1, d$3, v$4, immutable$5, true);
    }
    return $t$2;
  }
};
const Rt$Events$control = (p$1, node$2, d$3, v$4) => {
  const immutable$5 = Html$Runtime$propertyImmutable(d$3);
  const $t$1 = p$1.controls(node$2);
  let $t$2;
  if ($t$1 !== Js$optNone) {
    $t$2 = Rt$Events$place(node$2, $t$1, d$3, v$4, immutable$5);
  } else {
    p$1.setControls(node$2, Rt$Events$entry(d$3, v$4));
    Rt$Events$watch(p$1);
    $t$2 = Rt$Events$apply(node$2, d$3, v$4, immutable$5, true);
  }
  return $t$2;
};
const Rt$Events$edited = (node$1) => Browser$Host$Set$add(Rt$Events$touched, node$1);
const Rt$Events$renderEnded = (root$1) => {
  const $t$1 = Rt$Events$afterRender;
  return $t$1 !== Js$optNone ? $t$1(root$1) : null;
};
export { Rt$Events$fire, Rt$Events$delegate, Rt$Events$listen, Rt$Events$control, Rt$Events$edited, Rt$Events$renderEnded };
//# sourceMappingURL=Events.mjs.map
