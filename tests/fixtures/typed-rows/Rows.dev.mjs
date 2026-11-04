import { Js$optNone } from "../../_core/Js.mjs";
import { Js$Protocol$defect } from "../../_core/Js/Protocol.mjs";
import { Js$Any$pack } from "../../_core/Js/Any.mjs";
import { Browser$Host$Array$make, Browser$Host$Array$size, Browser$Host$Array$length, Browser$Host$Array$atOr, Browser$Host$Array$set, Browser$Host$Array$push, Browser$Host$Array$fromList, Browser$Host$Array$slice } from "../../_core/Browser/Host/Array.mjs";
import { Browser$Host$KeyMap$make, Browser$Host$KeyMap$has, Browser$Host$KeyMap$set, Browser$Host$KeyMap$getOr, Browser$Host$KeyMap$clear, Browser$Host$KeyMap$remove } from "../../_core/Browser/Host/KeyMap.mjs";
import { Html$Runtime$slotCell, Html$Runtime$rowCell } from "../../_platform/_html/Html/Runtime.mjs";
import { List$unsafeGet } from "../../_core/List.mjs";
const Rt$Rows$required = (value$1) => {
  let $t$2;
  if (value$1 !== Js$optNone) {
    const $t$1 = value$1 && value$1.$opt === Js$optNone ? value$1.$previous : value$1;
    $t$2 = $t$1;
  } else {
    $t$2 = Js$Protocol$defect("missing renderer row state");
  }
  return $t$2;
};
const Rt$Rows$unpack = ($m$0, $p$1, data$1) => {
  const $t$2 = data$1[Js$Any$pack.$packet.key];
  return ($t$2 !== undefined ? $t$2 === "core:Js.Cell({d=core:Basics.Bool,keyed=core:Basics.Bool,u=core:Browser.Host.Array.Array(platform:Html.Runtime.Row(" + $m$0 + ")),x=core:Js.Opt(core:Browser.Host.KeyMap.Map(" + $m$0 + ",platform:Html.Runtime.Row(" + $m$0 + "))),y=core:Js.Opt(core:Js.Any.Any),z=core:Js.Opt(" + $m$0 + ")})" : data$1.type === "core:Js.Cell({d=core:Basics.Bool,keyed=core:Basics.Bool,u=core:Browser.Host.Array.Array(platform:Html.Runtime.Row(" + $m$0 + ")),x=core:Js.Opt(core:Browser.Host.KeyMap.Map(" + $m$0 + ",platform:Html.Runtime.Row(" + $m$0 + "))),y=core:Js.Opt(core:Js.Any.Any),z=core:Js.Opt(" + $m$0 + ")})") ? $t$2 !== undefined ? data$1 : data$1.value : Js$optNone;
};
const Rt$Rows$unpackShow = ($m$0, $p$1, data$1) => {
  const $t$2 = data$1[Js$Any$pack.$packet.key];
  return ($t$2 !== undefined ? $t$2 === "core:Js.Cell({key=" + $m$0 + "})" : data$1.type === "core:Js.Cell({key=" + $m$0 + "})") ? $t$2 !== undefined ? data$1 : data$1.value : Js$optNone;
};
const Rt$Rows$newState = ($m$0, protocol$1, location$2, $p$1, keyed$3, callbacks$4, scope$5) => {
  const $t$2 = Browser$Host$Array$make(null);
  const $t$3 = keyed$3 ? Browser$Host$KeyMap$make(null) : Js$optNone;
  const state$6 = { d: false, keyed: keyed$3, u: $t$2, x: $t$3, y: Js$optNone, z: Js$optNone };
  const fields$7 = Html$Runtime$slotCell(location$2);
  fields$7.r = protocol$1.makeSite(callbacks$4, scope$5, Js$Any$pack("core:Js.Cell({d=core:Basics.Bool,keyed=core:Basics.Bool,u=core:Browser.Host.Array.Array(platform:Html.Runtime.Row(" + $m$0 + ")),x=core:Js.Opt(core:Browser.Host.KeyMap.Map(" + $m$0 + ",platform:Html.Runtime.Row(" + $m$0 + "))),y=core:Js.Opt(core:Js.Any.Any),z=core:Js.Opt(" + $m$0 + ")})", state$6));
  fields$7.v = false;
  fields$7.w = false;
  return state$6;
};
const Rt$Rows$stateFor = ($m$0, protocol$1, location$2, recipe$3, keyed$4, callbacks$5, scope$6) => {
  const $t$1 = Html$Runtime$slotCell(location$2).r;
  let $t$5;
  if ($t$1 !== Js$optNone) {
    const $t$2 = Rt$Rows$unpack($m$0, recipe$3, protocol$1.siteData($t$1));
    let $t$4;
    if ($t$2 !== Js$optNone) {
      let $t$3;
      if ($t$2.keyed === keyed$4) {
        protocol$1.setSiteScope($t$1, callbacks$5, scope$6);
        $t$3 = $t$2;
      } else {
        protocol$1.siteDispose($t$1, location$2);
        $t$3 = Rt$Rows$newState($m$0, protocol$1, location$2, recipe$3, keyed$4, callbacks$5, scope$6);
      }
      $t$4 = $t$3;
    } else {
      protocol$1.siteDispose($t$1, location$2);
      $t$4 = Rt$Rows$newState($m$0, protocol$1, location$2, recipe$3, keyed$4, callbacks$5, scope$6);
    }
    $t$5 = $t$4;
  } else {
    $t$5 = Rt$Rows$newState($m$0, protocol$1, location$2, recipe$3, keyed$4, callbacks$5, scope$6);
  }
  return $t$5;
};
const Rt$Rows$singleHead = (protocol$1, location$2) => {
  const fields$3 = Html$Runtime$slotCell(location$2);
  const $t$1 = fields$3.i;
  return $t$1 !== Js$optNone ? protocol$1.first($t$1) : fields$3.m;
};
const Rt$Rows$singleTail = (protocol$1, location$2) => {
  const fields$3 = Html$Runtime$slotCell(location$2);
  const $t$1 = fields$3.m;
  let $t$3;
  if ($t$1 !== Js$optNone) {
    $t$3 = $t$1;
  } else {
    const $t$2 = fields$3.i;
    $t$3 = $t$2 !== Js$optNone ? protocol$1.last($t$2) : Js$optNone;
  }
  return $t$3;
};
const Rt$Rows$head = ($m$0, protocol$1, recipe$2, data$3, location$4) => {
  const $t$1 = Rt$Rows$unpack($m$0, recipe$2, data$3);
  let $t$3;
  if ($t$1 !== Js$optNone) {
    const rows$6 = $t$1.u;
    let $t$2;
    if (Browser$Host$Array$size(rows$6) === 0) {
      $t$2 = Rt$Rows$singleHead(protocol$1, location$4);
    } else {
      if (0 !== 0 >>> 0 || 0 >= rows$6.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      $t$2 = protocol$1.first(recipe$2.view(rows$6[0]));
    }
    $t$3 = $t$2;
  } else {
    $t$3 = Rt$Rows$singleHead(protocol$1, location$4);
  }
  return $t$3;
};
const Rt$Rows$tail = ($m$0, protocol$1, recipe$2, data$3, location$4) => {
  const fields$5 = Html$Runtime$slotCell(location$4);
  const $t$1 = fields$5.m;
  let $t$6;
  if ($t$1 !== Js$optNone) {
    $t$6 = $t$1;
  } else {
    const $t$2 = Rt$Rows$unpack($m$0, recipe$2, data$3);
    let $t$5;
    if ($t$2 !== Js$optNone) {
      const rows$8 = $t$2.u;
      let $t$4;
      if (Browser$Host$Array$size(rows$8) === 0) {
        $t$4 = Rt$Rows$singleTail(protocol$1, location$4);
      } else {
        const $t$3 = Browser$Host$Array$size(rows$8) - 1;
        if ($t$3 !== $t$3 >>> 0 || $t$3 >= rows$8.length) {
          throw new globalThis.RangeError("beni: renderer array index out of bounds");
        }
        $t$4 = protocol$1.last(recipe$2.view(rows$8[$t$3]));
      }
      $t$5 = $t$4;
    } else {
      $t$5 = Rt$Rows$singleTail(protocol$1, location$4);
    }
    $t$6 = $t$5;
  }
  return $t$6;
};
const Rt$Rows$restateRows = (protocol$1, recipe$2, rows$3, stamp$4, $in$4, $in$5) => {
  for (;;) {
    const index$5 = $in$4;
    const live$6 = $in$5;
    if (index$5 === Browser$Host$Array$size(rows$3)) {
      return live$6;
    } else {
      if (index$5 !== index$5 >>> 0 || index$5 >= rows$3.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$7 = rows$3[index$5];
      const instance$8 = recipe$2.view(value$7);
      if (protocol$1.live(instance$8) && Html$Runtime$rowCell(value$7).rs !== stamp$4) {
        if (recipe$2.e) {
          recipe$2.p(value$7, recipe$2.item(value$7), Html$Runtime$rowCell(value$7).y);
        } else {
          recipe$2.r(value$7);
        }
      }
      $in$4 = index$5 + 1;
      $in$5 = live$6 || protocol$1.live(instance$8);
    }
  }
};
const Rt$Rows$restate = ($m$0, protocol$1, recipe$2, data$3, location$4, stamp$5) => {
  const $t$1 = Rt$Rows$unpack($m$0, recipe$2, data$3);
  let $t$2;
  if ($t$1 !== Js$optNone) {
    const live$7 = Rt$Rows$restateRows(protocol$1, recipe$2, $t$1.u, stamp$5, 0, false);
    Html$Runtime$slotCell(location$4).w = live$7;
    $t$2 = null;
  } else {
    $t$2 = null;
  }
  return $t$2;
};
const Rt$Rows$disposeRows = (protocol$1, recipe$2, rows$3, index$4) => {
  while (index$4 < Browser$Host$Array$size(rows$3)) {
    if (index$4 !== index$4 >>> 0 || index$4 >= rows$3.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    protocol$1.drop(recipe$2.view(rows$3[index$4]));
    index$4 = index$4 + 1;
  }
  return null;
};
const Rt$Rows$dispose = ($m$0, protocol$1, recipe$2, data$3, location$4) => {
  const $t$1 = Rt$Rows$unpack($m$0, recipe$2, data$3);
  if ($t$1 !== Js$optNone) {
    Rt$Rows$disposeRows(protocol$1, recipe$2, $t$1.u, 0);
  }
  const fields$5 = Html$Runtime$slotCell(location$4);
  const $t$2 = fields$5.i;
  if ($t$2 !== Js$optNone) {
    protocol$1.drop($t$2);
  }
  fields$5.i = Js$optNone;
  fields$5.r = Js$optNone;
  fields$5.l = false;
  fields$5.w = false;
  fields$5.v = false;
  return null;
};
const Rt$Rows$startPass = (location$1, recipe$2) => {
  if (recipe$2.l) {
    const fields$3 = Html$Runtime$slotCell(location$1);
    fields$3.k = fields$3.k + 1;
  }
};
const Rt$Rows$passed = (protocol$1, location$2, recipe$3, value$4) => {
  if (recipe$3.l && protocol$1.live(recipe$3.view(value$4))) {
    const fields$5 = Html$Runtime$slotCell(location$2);
    Html$Runtime$rowCell(value$4).rs = fields$5.k;
    fields$5.w = true;
    return null;
  } else {
    return null;
  }
};
const Rt$Rows$endPass = (protocol$1, location$2, recipe$3, state$4) => {
  const fields$5 = Html$Runtime$slotCell(location$2);
  if (fields$5.w) {
    const live$7 = Rt$Rows$restateRows(protocol$1, recipe$3, state$4.u, fields$5.k, 0, false);
    fields$5.w = live$7;
    return null;
  } else {
    return null;
  }
};
const Rt$Rows$mountRow = (protocol$1, location$2, recipe$3, item$4, key$5, position$6) => {
  const value$7 = recipe$3.m(item$4, key$5, position$6, Html$Runtime$slotCell(location$2).cx);
  Rt$Rows$passed(protocol$1, location$2, recipe$3, value$7);
  return value$7;
};
const Rt$Rows$patchRow = (protocol$1, location$2, recipe$3, old$4, item$5, position$6) => {
  const value$7 = recipe$3.p(old$4, item$5, position$6);
  if (!(value$7 === old$4)) {
    const fields$8 = Html$Runtime$rowCell(value$7);
    const previous$9 = Html$Runtime$rowCell(old$4);
    fields$8.k = previous$9.k;
    fields$8.n = Js$optNone;
    fields$8.kv = 0;
    fields$8.kc = previous$9.kc;
    fields$8.kt = Js$optNone;
  }
  Rt$Rows$passed(protocol$1, location$2, recipe$3, value$7);
  return value$7;
};
const Rt$Rows$sameProbe = (a$1, b$2) => {
  let $t$6;
  if (a$1 !== Js$optNone) {
    const $t$3 = a$1 && a$1.$opt === Js$optNone ? a$1.$previous : a$1;
    let $t$5;
    if (b$2 !== Js$optNone) {
      const $t$4 = b$2 && b$2.$opt === Js$optNone ? b$2.$previous : b$2;
      $t$5 = $t$3 === $t$4;
    } else {
      $t$5 = false;
    }
    $t$6 = $t$5;
  } else {
    let $t$2;
    if (b$2 !== Js$optNone) {
      const $t$1 = b$2 && b$2.$opt === Js$optNone ? b$2.$previous : b$2;
      $t$2 = false;
    } else {
      $t$2 = true;
    }
    $t$6 = $t$2;
  }
  return $t$6;
};
const Rt$Rows$probed = (key$1, probe$2) => {
  let $t$2;
  if (probe$2 !== Js$optNone) {
    const $t$1 = probe$2 && probe$2.$opt === Js$optNone ? probe$2.$previous : probe$2;
    $t$2 = key$1 === $t$1;
  } else {
    $t$2 = false;
  }
  return $t$2;
};
const Rt$Rows$positionsFrom = (protocol$1, location$2, rows$3, values$4, first$5, recipe$6, same$7, index$8) => {
  while (index$8 < Browser$Host$Array$length(values$4)) {
    const item$9 = Browser$Host$Array$atOr(values$4, index$8, first$5);
    if (index$8 < Browser$Host$Array$size(rows$3)) {
      if (index$8 !== index$8 >>> 0 || index$8 >= rows$3.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const old$10 = rows$3[index$8];
      if (!same$7 || !recipe$6.o || !recipe$6.sameItem(old$10, item$9)) {
        const value$11 = Rt$Rows$patchRow(protocol$1, location$2, recipe$6, old$10, item$9, index$8);
        Browser$Host$Array$set(rows$3, index$8, value$11);
        recipe$6.setItem(value$11, item$9);
      }
    } else {
      const value$12 = Rt$Rows$mountRow(protocol$1, location$2, recipe$6, item$9, null, index$8);
      protocol$1.put(protocol$1.parentOf(location$2), recipe$6.view(value$12), Rt$Rows$singleHead(protocol$1, location$2));
      Browser$Host$Array$push(rows$3, value$12);
    }
    index$8 = index$8 + 1;
  }
  return null;
};
const Rt$Rows$dropPastFrom = (protocol$1, rows$2, recipe$3, index$4, length$5) => {
  while (index$4 >= length$5) {
    if (index$4 !== index$4 >>> 0 || index$4 >= rows$2.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    protocol$1.drop(recipe$3.view(rows$2[index$4]));
    index$4 = index$4 - 1;
  }
  return null;
};
const Rt$Rows$dropPast = (protocol$1, rows$2, recipe$3, length$4) => {
  if (Browser$Host$Array$size(rows$2) > length$4) {
    Rt$Rows$dropPastFrom(protocol$1, rows$2, recipe$3, Browser$Host$Array$size(rows$2) - 1, length$4);
    rows$2.length = length$4;
    return null;
  } else {
    return null;
  }
};
const Rt$Rows$forPosition = (protocol$1, location$2, items$3, recipe$4, inputs$5, callbacks$6, scope$7) => {
  const state$8 = Rt$Rows$stateFor("()", protocol$1, location$2, recipe$4, false, callbacks$6, scope$7);
  Rt$Rows$startPass(location$2, recipe$4);
  const fields$9 = Html$Runtime$slotCell(location$2);
  const same$10 = fields$9.v && fields$9.j === recipe$4.j && recipe$4.same(state$8.y, inputs$5);
  fields$9.j = recipe$4.j;
  fields$9.v = true;
  state$8.y = recipe$4.remember(inputs$5);
  const rows$11 = state$8.u;
  const values$12 = Browser$Host$Array$fromList(items$3);
  if (items$3.length !== 0) {
    const first$20 = List$unsafeGet(items$3, 0);
    Rt$Rows$positionsFrom(protocol$1, location$2, rows$11, values$12, first$20, recipe$4, same$10, 0);
  }
  Rt$Rows$dropPast(protocol$1, rows$11, recipe$4, Browser$Host$Array$length(values$12));
  Rt$Rows$endPass(protocol$1, location$2, recipe$4, state$8);
  return protocol$1.childMaybe(location$2, Browser$Host$Array$length(values$12) === 0 ? recipe$4.f : Js$optNone);
};
const Rt$Rows$newShow = ($m$0, protocol$1, location$2, key$3, callbacks$4, scope$5) => {
  const state$6 = { key: key$3 };
  const fields$7 = Html$Runtime$slotCell(location$2);
  fields$7.r = protocol$1.makeSite(callbacks$4, scope$5, Js$Any$pack("core:Js.Cell({key=" + $m$0 + "})", state$6));
  fields$7.v = false;
  return state$6;
};
const Rt$Rows$placeBlock = (protocol$1, location$2, block$3) => {
  const fields$4 = Html$Runtime$slotCell(location$2);
  const value$5 = protocol$1.unit(block$3, fields$4.cx);
  const $t$1 = fields$4.i;
  if ($t$1 !== Js$optNone) {
    protocol$1.swap($t$1, value$5);
  } else {
    protocol$1.put(protocol$1.parentOf(location$2), value$5, fields$4.m);
  }
  fields$4.i = value$5;
  fields$4.l = protocol$1.live(value$5);
  return null;
};
const Rt$Rows$show = ($m$0, protocol$1, location$2, key$3, block$4, identityTag$5, callbacks$6, scope$7) => {
  const fields$8 = Html$Runtime$slotCell(location$2);
  const $t$1 = fields$8.r;
  let $t$4;
  if ($t$1 !== Js$optNone) {
    const $t$2 = Rt$Rows$unpackShow($m$0, key$3, protocol$1.siteData($t$1));
    let $t$3;
    if ($t$2 !== Js$optNone) {
      protocol$1.setSiteScope($t$1, callbacks$6, scope$7);
      $t$3 = $t$2;
    } else {
      protocol$1.siteDispose($t$1, location$2);
      $t$3 = Rt$Rows$newShow($m$0, protocol$1, location$2, key$3, callbacks$6, scope$7);
    }
    $t$4 = $t$3;
  } else {
    $t$4 = Rt$Rows$newShow($m$0, protocol$1, location$2, key$3, callbacks$6, scope$7);
  }
  const state$9 = $t$4;
  if (fields$8.v && state$9.key === key$3) {
    protocol$1.childMaybe(location$2, block$4);
  } else {
    Rt$Rows$placeBlock(protocol$1, location$2, block$4);
  }
  state$9.key = key$3;
  fields$8.j = identityTag$5;
  fields$8.v = true;
  return null;
};
const Rt$Rows$hide = (protocol$1, location$2, fallback$3) => {
  const fields$4 = Html$Runtime$slotCell(location$2);
  if (fallback$3 !== Js$optNone) {
    if (!fields$4.v) {
      protocol$1.childMaybe(location$2, fallback$3);
    } else {
      Rt$Rows$placeBlock(protocol$1, location$2, fallback$3);
    }
  } else {
    protocol$1.childMaybe(location$2, fallback$3);
  }
  fields$4.v = false;
  return null;
};
let Rt$Rows$parked = Js$optNone;
const Rt$Rows$park = (protocol$1, recipe$2, value$3) => {
  const instance$4 = recipe$2.view(value$3);
  const first$5 = protocol$1.first(instance$4);
  if (first$5 === protocol$1.last(instance$4)) {
    const $t$1 = first$5.parentNode;
    if ($t$1 !== null) {
      $t$1.removeChild(first$5);
    }
    return null;
  } else {
    const $t$2 = Rt$Rows$parked;
    let $t$3;
    if ($t$2 !== Js$optNone) {
      $t$3 = $t$2;
    } else {
      const created$7 = globalThis.document.createDocumentFragment();
      Rt$Rows$parked = created$7;
      $t$3 = created$7;
    }
    const fragment$6 = $t$3;
    return protocol$1.put(fragment$6, instance$4, Js$optNone);
  }
};
const Rt$Rows$sameEnds = (a$1, b$2, aStart$3, aEnd$4, bStart$5, bEnd$6) => {
  for (;;) {
    let $t$4 = aEnd$4 > aStart$3 && bEnd$6 > bStart$5;
    if ($t$4) {
      const $t$1 = aEnd$4 - 1;
      if ($t$1 !== $t$1 >>> 0 || $t$1 >= a$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const $t$3 = a$1[$t$1];
      const $t$2 = bEnd$6 - 1;
      if ($t$2 !== $t$2 >>> 0 || $t$2 >= b$2.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      $t$4 = $t$3 === b$2[$t$2];
    }
    if ($t$4) {
      aEnd$4 = aEnd$4 - 1;
      bEnd$6 = bEnd$6 - 1;
    } else {
      return { a: aEnd$4, b: bEnd$6 };
    }
  }
};
const Rt$Rows$putRange = (protocol$1, recipe$2, parent$3, rows$4, from$5, to$6, node$7) => {
  while (from$5 < to$6) {
    if (from$5 !== from$5 >>> 0 || from$5 >= rows$4.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    protocol$1.put(parent$3, recipe$2.view(rows$4[from$5]), node$7);
    from$5 = from$5 + 1;
  }
  return null;
};
const Rt$Rows$dropRange = (protocol$1, recipe$2, rows$3, indices$4, $in$4, to$6) => {
  for (;;) {
    const from$5 = $in$4;
    if (from$5 < to$6) {
      if (from$5 !== from$5 >>> 0 || from$5 >= rows$3.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$7 = rows$3[from$5];
      const keep$8 = indices$4 !== Js$optNone ? Browser$Host$KeyMap$has(indices$4, value$7) : false;
      if (!keep$8) {
        protocol$1.drop(recipe$2.view(value$7));
      }
      $in$4 = from$5 + 1;
    } else {
      return null;
    }
  }
};
const Rt$Rows$indexRange = (positions$1, rows$2, from$3, to$4) => {
  while (from$3 < to$4) {
    if (from$3 !== from$3 >>> 0 || from$3 >= rows$2.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    Browser$Host$KeyMap$set(positions$1, rows$2[from$3], from$3);
    from$3 = from$3 + 1;
  }
};
const Rt$Rows$sameRun = (positions$1, rows$2, aEnd$3, bEnd$4, index$5, i$6, sequence$7) => {
  for (;;) {
    let $t$1 = i$6 < aEnd$3 && i$6 < bEnd$4;
    if ($t$1) {
      if (i$6 !== i$6 >>> 0 || i$6 >= rows$2.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      $t$1 = Browser$Host$KeyMap$getOr(positions$1, rows$2[i$6], 0 - 1) === index$5 + sequence$7;
    }
    if ($t$1) {
      i$6 = i$6 + 1;
      sequence$7 = sequence$7 + 1;
    } else {
      return sequence$7;
    }
  }
};
const Rt$Rows$reconcile = (protocol$1, recipe$2, parent$3, a$4, b$5, bLength$6, after$7, $in$7, $in$8, $in$9, $in$10, $in$11) => {
  for (;;) {
    const aStart$8 = $in$7;
    const aEnd$9 = $in$8;
    const bStart$10 = $in$9;
    const bEnd$11 = $in$10;
    const indices$12 = $in$11;
    if (!(aStart$8 < aEnd$9 || bStart$10 < bEnd$11)) {
      return null;
    } else {
      let $t$2 = aStart$8 < aEnd$9 && bStart$10 < bEnd$11;
      if ($t$2) {
        if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
          throw new globalThis.RangeError("beni: renderer array index out of bounds");
        }
        const $t$1 = a$4[aStart$8];
        if (bStart$10 !== bStart$10 >>> 0 || bStart$10 >= b$5.length) {
          throw new globalThis.RangeError("beni: renderer array index out of bounds");
        }
        $t$2 = $t$1 === b$5[bStart$10];
      }
      if ($t$2) {
        $in$7 = aStart$8 + 1;
        $in$8 = aEnd$9;
        $in$9 = bStart$10 + 1;
        $in$10 = bEnd$11;
        $in$11 = indices$12;
      } else {
        const $t$3 = Rt$Rows$sameEnds(a$4, b$5, aStart$8, aEnd$9, bStart$10, bEnd$11);
        const aTo$13 = $t$3.a;
        const bTo$14 = $t$3.b;
        if (aTo$13 === aStart$8) {
          let $t$4;
          if (bTo$14 < bLength$6) {
            let $t$8;
            if (bStart$10 !== 0) {
              const $t$5 = bStart$10 - 1;
              if ($t$5 !== $t$5 >>> 0 || $t$5 >= b$5.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const $t$6 = protocol$1.last(recipe$2.view(b$5[$t$5]));
              const $t$7 = $t$6.nextSibling;
              $t$8 = $t$7 === null ? Js$optNone : $t$7;
            } else {
              if (bTo$14 !== bTo$14 >>> 0 || bTo$14 >= b$5.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              $t$8 = protocol$1.first(recipe$2.view(b$5[bTo$14]));
            }
            $t$4 = $t$8;
          } else {
            $t$4 = after$7;
          }
          const node$15 = $t$4;
          Rt$Rows$putRange(protocol$1, recipe$2, parent$3, b$5, bStart$10, bTo$14, node$15);
          $in$7 = aStart$8;
          $in$8 = aTo$13;
          $in$9 = bTo$14;
          $in$10 = bTo$14;
          $in$11 = indices$12;
        } else {
          if (bTo$14 === bStart$10) {
            Rt$Rows$dropRange(protocol$1, recipe$2, a$4, indices$12, aStart$8, aTo$13);
            $in$7 = aTo$13;
            $in$8 = aTo$13;
            $in$9 = bStart$10;
            $in$10 = bTo$14;
            $in$11 = indices$12;
          } else {
            if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
              throw new globalThis.RangeError("beni: renderer array index out of bounds");
            }
            const $t$10 = a$4[aStart$8];
            const $t$9 = bTo$14 - 1;
            if ($t$9 !== $t$9 >>> 0 || $t$9 >= b$5.length) {
              throw new globalThis.RangeError("beni: renderer array index out of bounds");
            }
            let $t$13 = $t$10 === b$5[$t$9];
            if ($t$13) {
              if (bStart$10 !== bStart$10 >>> 0 || bStart$10 >= b$5.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const $t$12 = b$5[bStart$10];
              const $t$11 = aTo$13 - 1;
              if ($t$11 !== $t$11 >>> 0 || $t$11 >= a$4.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              $t$13 = $t$12 === a$4[$t$11];
            }
            if ($t$13) {
              const $t$14 = aTo$13 - 1;
              if ($t$14 !== $t$14 >>> 0 || $t$14 >= a$4.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const $t$15 = protocol$1.last(recipe$2.view(a$4[$t$14]));
              const $t$16 = $t$15.nextSibling;
              const node$16 = $t$16 === null ? Js$optNone : $t$16;
              if (bStart$10 !== bStart$10 >>> 0 || bStart$10 >= b$5.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const moving$17 = recipe$2.view(b$5[bStart$10]);
              if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const $t$17 = protocol$1.last(recipe$2.view(a$4[aStart$8]));
              const $t$18 = $t$17.nextSibling;
              const before$18 = $t$18 === null ? Js$optNone : $t$18;
              if (protocol$1.first(moving$17) === protocol$1.last(moving$17) || (before$18 !== Js$optNone ? !(before$18 === protocol$1.first(moving$17)) : true)) {
                protocol$1.put(parent$3, moving$17, before$18);
              }
              const $t$19 = bTo$14 - 1;
              if ($t$19 !== $t$19 >>> 0 || $t$19 >= b$5.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              protocol$1.put(parent$3, recipe$2.view(b$5[$t$19]), node$16);
              const $t$21 = aTo$13 - 1;
              const $t$20 = bTo$14 - 1;
              if ($t$20 !== $t$20 >>> 0 || $t$20 >= b$5.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              Browser$Host$Array$set(a$4, $t$21, b$5[$t$20]);
              $in$7 = aStart$8 + 1;
              $in$8 = aTo$13 - 1;
              $in$9 = bStart$10 + 1;
              $in$10 = bTo$14 - 1;
              $in$11 = indices$12;
            } else {
              let $t$22;
              if (indices$12 !== Js$optNone) {
                $t$22 = indices$12;
              } else {
                const created$22 = Browser$Host$KeyMap$make(null);
                Rt$Rows$indexRange(created$22, b$5, bStart$10, bTo$14);
                $t$22 = created$22;
              }
              const positions$20 = $t$22;
              if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const found$21 = Browser$Host$KeyMap$getOr(positions$20, a$4[aStart$8], 0 - 1);
              if (found$21 < 0) {
                if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
                  throw new globalThis.RangeError("beni: renderer array index out of bounds");
                }
                protocol$1.drop(recipe$2.view(a$4[aStart$8]));
                $in$7 = aStart$8 + 1;
                $in$8 = aTo$13;
                $in$9 = bStart$10;
                $in$10 = bTo$14;
                $in$11 = positions$20;
              } else {
                if (bStart$10 < found$21 && found$21 < bTo$14) {
                  const sequence$24 = Rt$Rows$sameRun(positions$20, a$4, aTo$13, bTo$14, found$21, aStart$8 + 1, 1);
                  if (sequence$24 > found$21 - bStart$10) {
                    if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
                      throw new globalThis.RangeError("beni: renderer array index out of bounds");
                    }
                    Rt$Rows$putRange(protocol$1, recipe$2, parent$3, b$5, bStart$10, found$21, protocol$1.first(recipe$2.view(a$4[aStart$8])));
                    $in$7 = aStart$8;
                    $in$8 = aTo$13;
                    $in$9 = found$21;
                    $in$10 = bTo$14;
                    $in$11 = positions$20;
                  } else {
                    if (aStart$8 !== aStart$8 >>> 0 || aStart$8 >= a$4.length) {
                      throw new globalThis.RangeError("beni: renderer array index out of bounds");
                    }
                    const old$25 = a$4[aStart$8];
                    if (bStart$10 !== bStart$10 >>> 0 || bStart$10 >= b$5.length) {
                      throw new globalThis.RangeError("beni: renderer array index out of bounds");
                    }
                    protocol$1.put(parent$3, recipe$2.view(b$5[bStart$10]), protocol$1.first(recipe$2.view(old$25)));
                    Rt$Rows$park(protocol$1, recipe$2, old$25);
                    $in$7 = aStart$8 + 1;
                    $in$8 = aTo$13;
                    $in$9 = bStart$10 + 1;
                    $in$10 = bTo$14;
                    $in$11 = positions$20;
                  }
                } else {
                  $in$7 = aStart$8 + 1;
                  $in$8 = aTo$13;
                  $in$9 = bStart$10;
                  $in$10 = bTo$14;
                  $in$11 = positions$20;
                }
              }
            }
          }
        }
      }
    }
  }
};
let Rt$Rows$stamps = 0;
const Rt$Rows$sameKey = (a$1, b$2) => a$1 === b$2 || !(a$1 === a$1) && !(b$2 === b$2);
const Rt$Rows$lookup = (byKey$1, key$2, anchor$3) => {
  const found$4 = Browser$Host$KeyMap$getOr(byKey$1, key$2, anchor$3);
  return found$4 === anchor$3 && !Rt$Rows$sameKey(key$2, Html$Runtime$rowCell(anchor$3).k) ? Js$optNone : found$4;
};
const Rt$Rows$allChildren = (protocol$1, recipe$2, parent$3, rows$4) => {
  const $t$1 = parent$3.firstChild;
  const $t$2 = $t$1 === null ? Js$optNone : $t$1;
  if (0 !== 0 >>> 0 || 0 >= rows$4.length) {
    throw new globalThis.RangeError("beni: renderer array index out of bounds");
  }
  let $t$6 = $t$2 === protocol$1.first(recipe$2.view(rows$4[0]));
  if ($t$6) {
    const $t$3 = Browser$Host$Array$size(rows$4) - 1;
    if ($t$3 !== $t$3 >>> 0 || $t$3 >= rows$4.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    const $t$4 = protocol$1.last(recipe$2.view(rows$4[$t$3]));
    const $t$5 = $t$4.nextSibling;
    $t$6 = ($t$5 === null ? Js$optNone : $t$5) === Js$optNone;
  }
  return $t$6;
};
const Rt$Rows$emptyKeyed = (protocol$1, location$2, recipe$3, state$4) => {
  Rt$Rows$stamps = Rt$Rows$stamps + 1;
  const old$5 = state$4.u;
  const rows$6 = Browser$Host$Array$make(null);
  const byKey$7 = Rt$Rows$required(state$4.x);
  Browser$Host$KeyMap$clear(byKey$7);
  if (Browser$Host$Array$size(old$5) > 0) {
    const parent$10 = protocol$1.parentOf(location$2);
    if (Rt$Rows$allChildren(protocol$1, recipe$3, parent$10, old$5)) {
      parent$10.textContent = "";
    } else {
      const $t$1 = Browser$Host$Array$size(old$5) - 1;
      if ($t$1 !== $t$1 >>> 0 || $t$1 >= old$5.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const $t$2 = protocol$1.last(recipe$3.view(old$5[$t$1]));
      const $t$3 = $t$2.nextSibling;
      Rt$Rows$reconcile(protocol$1, recipe$3, parent$10, old$5, rows$6, 0, $t$3 === null ? Js$optNone : $t$3, 0, Browser$Host$Array$size(old$5), 0, 0, Js$optNone);
    }
    Rt$Rows$parked = Js$optNone;
  }
  state$4.u = rows$6;
  state$4.d = true;
  return null;
};
const Rt$Rows$startRows = (protocol$1, location$2, values$3, first$4, old$5, keyOf$6, recipe$7, state$8, stable$9, same$10, was$11, now$12, stamp$13, m$14, $in$14) => {
  for (;;) {
    const p$15 = $in$14;
    if (p$15 < Browser$Host$Array$length(values$3) && p$15 < m$14) {
      if (p$15 !== p$15 >>> 0 || p$15 >= old$5.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$16 = old$5[p$15];
      const fields$17 = Html$Runtime$rowCell(value$16);
      const item$18 = Browser$Host$Array$atOr(values$3, p$15, first$4);
      const hit$19 = stable$9 && recipe$7.o && recipe$7.sameItem(value$16, item$18);
      if (!hit$19 && !(fields$17.k === keyOf$6(item$18))) {
        return p$15;
      } else {
        if (hit$19 && same$10 && !Rt$Rows$probed(fields$17.k, was$11) && !Rt$Rows$probed(fields$17.k, now$12)) {
          fields$17.kv = stamp$13;
          $in$14 = p$15 + 1;
        } else {
          const patched$24 = Rt$Rows$patchRow(protocol$1, location$2, recipe$7, value$16, item$18, p$15);
          const patchedFields$25 = Html$Runtime$rowCell(patched$24);
          if (!(patched$24 === value$16)) {
            Browser$Host$Array$set(old$5, p$15, patched$24);
            Browser$Host$KeyMap$set(Rt$Rows$required(state$8.x), patchedFields$25.k, patched$24);
            patchedFields$25.y = p$15;
          }
          recipe$7.setItem(patched$24, item$18);
          patchedFields$25.kv = stamp$13;
          $in$14 = p$15 + 1;
        }
      }
    } else {
      return p$15;
    }
  }
};
const Rt$Rows$copyRows = (next$1, old$2, p$3, index$4) => {
  while (index$4 < p$3) {
    if (index$4 !== index$4 >>> 0 || index$4 >= old$2.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    Browser$Host$Array$set(next$1, index$4, old$2[index$4]);
    index$4 = index$4 + 1;
  }
};
const Rt$Rows$endRows = (old$1, values$2, first$3, keyAt$4, next$5, recipe$6, stable$7, p$8, stamp$9, $in$9, $in$10) => {
  for (;;) {
    const aEnd$10 = $in$9;
    const bEnd$11 = $in$10;
    if (p$8 < aEnd$10 && p$8 < bEnd$11) {
      const $t$1 = aEnd$10 - 1;
      if ($t$1 !== $t$1 >>> 0 || $t$1 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$12 = old$1[$t$1];
      const fields$13 = Html$Runtime$rowCell(value$12);
      if (!(stable$7 && recipe$6.o && recipe$6.sameItem(value$12, Browser$Host$Array$atOr(values$2, bEnd$11 - 1 - p$8, first$3))) && !(fields$13.k === keyAt$4(bEnd$11 - 1))) {
        return { a: aEnd$10, b: bEnd$11 };
      } else {
        fields$13.kv = stamp$9;
        Browser$Host$Array$set(next$5, bEnd$11 - 1, value$12);
        $in$9 = aEnd$10 - 1;
        $in$10 = bEnd$11 - 1;
      }
    } else {
      return { a: aEnd$10, b: bEnd$11 };
    }
  }
};
const Rt$Rows$crossStart = (old$1, hit$2, next$3, stamp$4, $in$4, aEnd$6, bEnd$7) => {
  for (;;) {
    const aStart$5 = $in$4;
    if (aStart$5 < aEnd$6 && aStart$5 < bEnd$7) {
      if (aStart$5 !== aStart$5 >>> 0 || aStart$5 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$8 = old$1[aStart$5];
      if (!hit$2(value$8, aStart$5)) {
        return aStart$5;
      } else {
        Html$Runtime$rowCell(value$8).kv = stamp$4;
        Browser$Host$Array$set(next$3, aStart$5, value$8);
        $in$4 = aStart$5 + 1;
      }
    } else {
      return aStart$5;
    }
  }
};
const Rt$Rows$crossEnd = (old$1, hit$2, next$3, stamp$4, aStart$5, $in$5, $in$6) => {
  for (;;) {
    const aEnd$6 = $in$5;
    const bEnd$7 = $in$6;
    let $t$2 = aStart$5 < aEnd$6 && aStart$5 < bEnd$7;
    if ($t$2) {
      const $t$1 = aEnd$6 - 1;
      if ($t$1 !== $t$1 >>> 0 || $t$1 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      $t$2 = hit$2(old$1[$t$1], bEnd$7 - 1);
    }
    if ($t$2) {
      const $t$3 = aEnd$6 - 1;
      if ($t$3 !== $t$3 >>> 0 || $t$3 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$8 = old$1[$t$3];
      Html$Runtime$rowCell(value$8).kv = stamp$4;
      Browser$Host$Array$set(next$3, bEnd$7 - 1, value$8);
      $in$5 = aEnd$6 - 1;
      $in$6 = bEnd$7 - 1;
    } else {
      return { a: aEnd$6, b: bEnd$7 };
    }
  }
};
const Rt$Rows$crossRows = (old$1, hit$2, next$3, stamp$4, $in$4, $in$5, $in$6) => {
  for (;;) {
    const aStart$5 = $in$4;
    const aEnd$6 = $in$5;
    const bEnd$7 = $in$6;
    let $t$1 = aEnd$6 - aStart$5 > 1 && bEnd$7 - aStart$5 > 1;
    if ($t$1) {
      if (aStart$5 !== aStart$5 >>> 0 || aStart$5 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      $t$1 = hit$2(old$1[aStart$5], bEnd$7 - 1);
    }
    if ($t$1) {
      const $t$2 = aEnd$6 - 1;
      if ($t$2 !== $t$2 >>> 0 || $t$2 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      $t$1 = hit$2(old$1[$t$2], aStart$5);
    }
    if ($t$1) {
      if (aStart$5 !== aStart$5 >>> 0 || aStart$5 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const i$8 = old$1[aStart$5];
      const $t$3 = aEnd$6 - 1;
      if ($t$3 !== $t$3 >>> 0 || $t$3 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const j$9 = old$1[$t$3];
      Html$Runtime$rowCell(i$8).kv = stamp$4;
      Html$Runtime$rowCell(j$9).kv = stamp$4;
      Browser$Host$Array$set(next$3, bEnd$7 - 1, i$8);
      Browser$Host$Array$set(next$3, aStart$5, j$9);
      const inner$10 = Rt$Rows$crossStart(old$1, hit$2, next$3, stamp$4, aStart$5 + 1, aEnd$6 - 1, bEnd$7 - 1);
      const $t$4 = Rt$Rows$crossEnd(old$1, hit$2, next$3, stamp$4, inner$10, aEnd$6 - 1, bEnd$7 - 1);
      const aTo$11 = $t$4.a;
      const bTo$12 = $t$4.b;
      $in$4 = inner$10;
      $in$5 = aTo$11;
      $in$6 = bTo$12;
    } else {
      return { a: aStart$5, b: aEnd$6, c: bEnd$7 };
    }
  }
};
const Rt$Rows$lookUpRows = (protocol$1, location$2, values$3, first$4, keyAt$5, next$6, recipe$7, byKey$8, anchor$9, p$10, stamp$11, unseen$12, bEnd$13, $in$13, $in$14) => {
  for (;;) {
    const b$14 = $in$13;
    const kept$15 = $in$14;
    if (b$14 < bEnd$13) {
      const key$16 = keyAt$5(b$14);
      const found$17 = Rt$Rows$lookup(byKey$8, key$16, anchor$9);
      if (found$17 !== Js$optNone ? true : false) {
        const value$18 = Rt$Rows$required(found$17);
        const fields$19 = Html$Runtime$rowCell(value$18);
        if (fields$19.kv === stamp$11 || fields$19.kv === unseen$12) {
          return { a: b$14, b: kept$15 };
        } else {
          fields$19.kv = stamp$11;
          Browser$Host$Array$set(next$6, b$14, value$18);
          $in$13 = b$14 + 1;
          $in$14 = kept$15 + 1;
        }
      } else {
        const value$23 = Rt$Rows$mountRow(protocol$1, location$2, recipe$7, Browser$Host$Array$atOr(values$3, b$14 - p$10, first$4), key$16, b$14);
        Html$Runtime$rowCell(value$23).kv = unseen$12;
        Browser$Host$KeyMap$set(byKey$8, key$16, value$23);
        Browser$Host$Array$set(next$6, b$14, value$23);
        $in$13 = b$14 + 1;
        $in$14 = kept$15;
      }
    } else {
      return { a: b$14, b: kept$15 };
    }
  }
};
const Rt$Rows$patchRows = (protocol$1, location$2, old$3, values$4, first$5, next$6, recipe$7, byKey$8, p$9, stamp$10, unseen$11, same$12, was$13, now$14, n$15, $in$15) => {
  for (;;) {
    const b$16 = $in$15;
    if (b$16 < n$15) {
      const item$17 = Browser$Host$Array$atOr(values$4, b$16 - p$9, first$5);
      if (b$16 !== b$16 >>> 0 || b$16 >= next$6.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$18 = next$6[b$16];
      const fields$19 = Html$Runtime$rowCell(value$18);
      if (fields$19.kv === unseen$11) {
        fields$19.kv = stamp$10;
      } else {
        if (!same$12 || !recipe$7.o || !recipe$7.sameItem(value$18, item$17) || recipe$7.i && fields$19.y !== b$16 || Rt$Rows$probed(fields$19.k, was$13) || Rt$Rows$probed(fields$19.k, now$14)) {
          const patched$26 = Rt$Rows$patchRow(protocol$1, location$2, recipe$7, value$18, item$17, b$16);
          if (!(patched$26 === value$18)) {
            Browser$Host$Array$set(old$3, fields$19.y, patched$26);
            Html$Runtime$rowCell(patched$26).kv = stamp$10;
            Browser$Host$KeyMap$set(byKey$8, Html$Runtime$rowCell(patched$26).k, patched$26);
            Browser$Host$Array$set(next$6, b$16, patched$26);
          }
        }
      }
      if (b$16 !== b$16 >>> 0 || b$16 >= next$6.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const shown$20 = next$6[b$16];
      recipe$7.setItem(shown$20, item$17);
      Html$Runtime$rowCell(shown$20).y = b$16;
      $in$15 = b$16 + 1;
    } else {
      return null;
    }
  }
};
const Rt$Rows$forgetRows = (old$1, byKey$2, stamp$3, $in$3, aEnd$5) => {
  for (;;) {
    const a$4 = $in$3;
    if (a$4 < aEnd$5) {
      if (a$4 !== a$4 >>> 0 || a$4 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$6 = old$1[a$4];
      if (Html$Runtime$rowCell(value$6).kv !== stamp$3) {
        Browser$Host$KeyMap$remove(byKey$2, Html$Runtime$rowCell(value$6).k);
      }
      $in$3 = a$4 + 1;
    } else {
      return;
    }
  }
};
const Rt$Rows$trimmed = (protocol$1, location$2, values$3, first$4, keyOf$5, recipe$6, state$7, stable$8, same$9, was$10, now$11) => {
  const old$12 = state$7.u;
  const m$13 = Browser$Host$Array$size(old$12);
  if (m$13 === 0) {
    return false;
  } else {
    Rt$Rows$stamps = Rt$Rows$stamps + 1;
    const stamp$15 = Rt$Rows$stamps;
    const p$16 = Rt$Rows$startRows(protocol$1, location$2, values$3, first$4, old$12, keyOf$5, recipe$6, state$7, stable$8, same$9, was$10, now$11, stamp$15, m$13, 0);
    if (p$16 === m$13 && p$16 === Browser$Host$Array$length(values$3)) {
      return true;
    } else {
      const xs$17 = Browser$Host$Array$slice(values$3, p$16);
      const n$18 = p$16 + Browser$Host$Array$length(xs$17);
      const keys$19 = Browser$Host$Array$make(null);
      const keyAt$20 = (b$32) => {
        const index$33 = b$32 - p$16;
        if (index$33 === index$33 >>> 0 && index$33 < keys$19.length && globalThis.Object.hasOwn(keys$19, index$33)) {
          if (index$33 !== index$33 >>> 0 || index$33 >= keys$19.length) {
            throw new globalThis.RangeError("beni: renderer array index out of bounds");
          }
          return keys$19[index$33];
        } else {
          const key$34 = keyOf$5(Browser$Host$Array$atOr(xs$17, index$33, first$4));
          Browser$Host$Array$set(keys$19, index$33, key$34);
          return key$34;
        }
      };
      const hit$21 = (value$35, b$36) => stable$8 && recipe$6.o && recipe$6.sameItem(value$35, Browser$Host$Array$atOr(xs$17, b$36 - p$16, first$4)) || Html$Runtime$rowCell(value$35).k === keyAt$20(b$36);
      const next$22 = Browser$Host$Array$make(null);
      Rt$Rows$copyRows(next$22, old$12, p$16, 0);
      const $t$1 = Rt$Rows$endRows(old$12, xs$17, first$4, keyAt$20, next$22, recipe$6, stable$8, p$16, stamp$15, m$13, n$18);
      const aOuter$23 = $t$1.a;
      const bOuter$24 = $t$1.b;
      const $t$2 = Rt$Rows$crossRows(old$12, hit$21, next$22, stamp$15, p$16, aOuter$23, bOuter$24);
      const aStart$25 = $t$2.a;
      const aEnd$26 = $t$2.b;
      const bEnd$27 = $t$2.c;
      const byKey$28 = Rt$Rows$required(state$7.x);
      const unseen$29 = 0 - stamp$15;
      if (0 !== 0 >>> 0 || 0 >= old$12.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const $t$3 = Rt$Rows$lookUpRows(protocol$1, location$2, xs$17, first$4, keyAt$20, next$22, recipe$6, byKey$28, old$12[0], p$16, stamp$15, unseen$29, bEnd$27, aStart$25, 0);
      const found$30 = $t$3.a;
      const kept$31 = $t$3.b;
      if (found$30 < bEnd$27) {
        return false;
      } else {
        Rt$Rows$patchRows(protocol$1, location$2, old$12, xs$17, first$4, next$22, recipe$6, byKey$28, p$16, stamp$15, unseen$29, same$9, was$10, now$11, n$18, p$16);
        Rt$Rows$forgetRows(old$12, byKey$28, stamp$15, aStart$25, aEnd$26);
        const parent$39 = protocol$1.parentOf(location$2);
        if (kept$31 === 0 && aStart$25 === p$16 && p$16 === 0 && aOuter$23 === m$13 && bOuter$24 === n$18 && Rt$Rows$allChildren(protocol$1, recipe$6, parent$39, old$12)) {
          parent$39.textContent = "";
          Rt$Rows$putRange(protocol$1, recipe$6, parent$39, next$22, 0, n$18, Js$optNone);
        } else {
          if (aStart$25 !== p$16 || aStart$25 < aEnd$26 || aStart$25 < bEnd$27) {
            let $t$7;
            if (bOuter$24 < n$18) {
              if (bOuter$24 !== bOuter$24 >>> 0 || bOuter$24 >= next$22.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              $t$7 = protocol$1.first(recipe$6.view(next$22[bOuter$24]));
            } else {
              const $t$4 = m$13 - 1;
              if ($t$4 !== $t$4 >>> 0 || $t$4 >= old$12.length) {
                throw new globalThis.RangeError("beni: renderer array index out of bounds");
              }
              const $t$5 = protocol$1.last(recipe$6.view(old$12[$t$4]));
              const $t$6 = $t$5.nextSibling;
              $t$7 = $t$6 === null ? Js$optNone : $t$6;
            }
            const after$40 = $t$7;
            Rt$Rows$reconcile(protocol$1, recipe$6, parent$39, old$12, next$22, bOuter$24, after$40, p$16, aOuter$23, p$16, bOuter$24, Js$optNone);
            Rt$Rows$parked = Js$optNone;
          }
        }
        state$7.u = next$22;
        return true;
      }
    }
  }
};
const Rt$Rows$keyedRows = (protocol$1, location$2, values$3, first$4, keyOf$5, recipe$6, same$7, was$8, now$9, stamp$10, old$11, byKey$12, next$13, $in$13, $in$14, $in$15, $in$16) => {
  for (;;) {
    const position$14 = $in$13;
    const distinct$15 = $in$14;
    const moved$16 = $in$15;
    const anchor$17 = $in$16;
    if (position$14 < Browser$Host$Array$length(values$3)) {
      const item$18 = Browser$Host$Array$atOr(values$3, position$14, first$4);
      const key$19 = keyOf$5(item$18);
      const h$20 = anchor$17 !== Js$optNone ? Rt$Rows$lookup(byKey$12, key$19, anchor$17) : Js$optNone;
      const starts$21 = h$20 !== Js$optNone ? Html$Runtime$rowCell(h$20).kv !== stamp$10 : true;
      let $t$3;
      if (h$20 !== Js$optNone) {
        const fields$31 = Html$Runtime$rowCell(h$20);
        let $t$1;
        if (starts$21) {
          fields$31.kc = fields$31.n;
          $t$1 = h$20;
        } else {
          const current$34 = fields$31.kc;
          let $t$2;
          if (current$34 !== Js$optNone) {
            fields$31.kc = Html$Runtime$rowCell(current$34).n;
            $t$2 = null;
          } else {
            $t$2 = null;
          }
          $t$1 = current$34;
        }
        $t$3 = $t$1;
      } else {
        $t$3 = Js$optNone;
      }
      const found$22 = $t$3;
      let $t$5;
      if (found$22 !== Js$optNone) {
        const fields$41 = Html$Runtime$rowCell(found$22);
        let $t$4;
        if (!same$7 || !recipe$6.o || !recipe$6.sameItem(found$22, item$18) || recipe$6.i && fields$41.y !== position$14 || Rt$Rows$probed(fields$41.k, was$8) || Rt$Rows$probed(fields$41.k, now$9)) {
          const oldPosition$45 = fields$41.y;
          const patched$46 = Rt$Rows$patchRow(protocol$1, location$2, recipe$6, found$22, item$18, position$14);
          if (!(patched$46 === found$22)) {
            Browser$Host$Array$set(old$11, oldPosition$45, patched$46);
            if (starts$21) {
              Browser$Host$KeyMap$set(byKey$12, key$19, patched$46);
            }
          }
          $t$4 = patched$46;
        } else {
          $t$4 = found$22;
        }
        $t$5 = $t$4;
      } else {
        const mounted$39 = Rt$Rows$mountRow(protocol$1, location$2, recipe$6, item$18, key$19, position$14);
        if (starts$21) {
          Browser$Host$KeyMap$set(byKey$12, key$19, mounted$39);
        }
        $t$5 = mounted$39;
      }
      const value$23 = $t$5;
      let $t$8 = moved$16;
      if (!$t$8) {
        let $t$7;
        if (found$22 !== Js$optNone) {
          let $t$6 = position$14 >= Browser$Host$Array$size(old$11);
          if (!$t$6) {
            if (position$14 !== position$14 >>> 0 || position$14 >= old$11.length) {
              throw new globalThis.RangeError("beni: renderer array index out of bounds");
            }
            $t$6 = !(old$11[position$14] === value$23);
          }
          $t$7 = $t$6;
        } else {
          $t$7 = true;
        }
        $t$8 = $t$7;
      }
      const shifted$24 = $t$8;
      const shownFields$25 = Html$Runtime$rowCell(value$23);
      shownFields$25.kv = stamp$10;
      recipe$6.setItem(value$23, item$18);
      shownFields$25.y = position$14;
      shownFields$25.n = Js$optNone;
      if (starts$21) {
        shownFields$25.kt = value$23;
      } else {
        const firstRow$52 = Html$Runtime$rowCell(Rt$Rows$required(h$20));
        Html$Runtime$rowCell(Rt$Rows$required(firstRow$52.kt)).n = value$23;
        firstRow$52.kt = value$23;
      }
      Browser$Host$Array$push(next$13, value$23);
      const nextAnchor$26 = anchor$17 !== Js$optNone ? anchor$17 : value$23;
      $in$13 = position$14 + 1;
      $in$14 = distinct$15 && starts$21;
      $in$15 = shifted$24;
      $in$16 = nextAnchor$26;
    } else {
      return { a: distinct$15, b: moved$16 };
    }
  }
};
const Rt$Rows$forgetOld = (old$1, byKey$2, stamp$3, anchor$4, $in$4) => {
  for (;;) {
    const index$5 = $in$4;
    if (index$5 < Browser$Host$Array$size(old$1)) {
      if (index$5 !== index$5 >>> 0 || index$5 >= old$1.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const value$6 = old$1[index$5];
      const fields$7 = Html$Runtime$rowCell(value$6);
      if (fields$7.kv !== stamp$3) {
        const $t$1 = Rt$Rows$lookup(byKey$2, fields$7.k, anchor$4);
        let $t$3;
        if ($t$1 !== Js$optNone) {
          let $t$2;
          if ($t$1 === value$6) {
            Browser$Host$KeyMap$remove(byKey$2, fields$7.k);
            $t$2 = null;
          } else {
            $t$2 = null;
          }
          $t$3 = $t$2;
        } else {
          $t$3 = null;
        }
      }
      $in$4 = index$5 + 1;
    } else {
      return;
    }
  }
};
const Rt$Rows$keyedPass = (protocol$1, location$2, values$3, first$4, keyOf$5, recipe$6, state$7, same$8, was$9, now$10) => {
  Rt$Rows$stamps = Rt$Rows$stamps + 1;
  const stamp$11 = Rt$Rows$stamps;
  const old$12 = state$7.u;
  const byKey$13 = Rt$Rows$required(state$7.x);
  const next$14 = Browser$Host$Array$make(null);
  let $t$1;
  if (Browser$Host$Array$size(old$12) === 0) {
    $t$1 = Js$optNone;
  } else {
    if (0 !== 0 >>> 0 || 0 >= old$12.length) {
      throw new globalThis.RangeError("beni: renderer array index out of bounds");
    }
    $t$1 = old$12[0];
  }
  const anchor$15 = $t$1;
  const $t$2 = Rt$Rows$keyedRows(protocol$1, location$2, values$3, first$4, keyOf$5, recipe$6, same$8, was$9, now$10, stamp$11, old$12, byKey$13, next$14, 0, true, false, anchor$15);
  const distinct$16 = $t$2.a;
  const shifted$17 = $t$2.b;
  if (0 !== 0 >>> 0 || 0 >= next$14.length) {
    throw new globalThis.RangeError("beni: renderer array index out of bounds");
  }
  Rt$Rows$forgetOld(old$12, byKey$13, stamp$11, next$14[0], 0);
  if (shifted$17 || Browser$Host$Array$size(next$14) !== Browser$Host$Array$size(old$12)) {
    const parent$20 = protocol$1.parentOf(location$2);
    if (Browser$Host$Array$size(old$12) === 0) {
      Rt$Rows$putRange(protocol$1, recipe$6, parent$20, next$14, 0, Browser$Host$Array$size(next$14), Rt$Rows$singleHead(protocol$1, location$2));
    } else {
      const $t$3 = Browser$Host$Array$size(old$12) - 1;
      if ($t$3 !== $t$3 >>> 0 || $t$3 >= old$12.length) {
        throw new globalThis.RangeError("beni: renderer array index out of bounds");
      }
      const $t$4 = protocol$1.last(recipe$6.view(old$12[$t$3]));
      const $t$5 = $t$4.nextSibling;
      const after$21 = $t$5 === null ? Js$optNone : $t$5;
      Rt$Rows$reconcile(protocol$1, recipe$6, parent$20, old$12, next$14, Browser$Host$Array$size(next$14), after$21, 0, Browser$Host$Array$size(old$12), 0, Browser$Host$Array$size(next$14), Js$optNone);
    }
    Rt$Rows$parked = Js$optNone;
  }
  state$7.u = next$14;
  state$7.d = distinct$16;
  return null;
};
const Rt$Rows$forKeyed = ($m$0, protocol$1, location$2, items$3, keyOf$4, recipe$5, inputs$6, callbacks$7, scope$8) => {
  const state$9 = Rt$Rows$stateFor($m$0, protocol$1, location$2, recipe$5, true, callbacks$7, scope$8);
  Rt$Rows$startPass(location$2, recipe$5);
  const fields$10 = Html$Runtime$slotCell(location$2);
  const rendered$11 = fields$10.v;
  const stable$12 = rendered$11 && fields$10.j === recipe$5.j;
  const same$13 = stable$12 && recipe$5.same(state$9.y, inputs$6);
  const probe$14 = recipe$5.probe(inputs$6);
  const moving$15 = rendered$11 && !Rt$Rows$sameProbe(state$9.z, probe$14);
  const was$16 = moving$15 ? state$9.z : Js$optNone;
  const now$17 = moving$15 ? probe$14 : Js$optNone;
  state$9.z = probe$14;
  fields$10.j = recipe$5.j;
  fields$10.v = true;
  state$9.y = recipe$5.remember(inputs$6);
  if (items$3.length === 0) {
    Rt$Rows$emptyKeyed(protocol$1, location$2, recipe$5, state$9);
  } else {
    const first$27 = List$unsafeGet(items$3, 0);
    const values$28 = Browser$Host$Array$fromList(items$3);
    if (!(state$9.d && Rt$Rows$trimmed(protocol$1, location$2, values$28, first$27, keyOf$4, recipe$5, state$9, stable$12, same$13, was$16, now$17))) {
      Rt$Rows$keyedPass(protocol$1, location$2, values$28, first$27, keyOf$4, recipe$5, state$9, same$13, was$16, now$17);
    }
  }
  Rt$Rows$endPass(protocol$1, location$2, recipe$5, state$9);
  return protocol$1.childMaybe(location$2, items$3.length === 0 ? recipe$5.f : Js$optNone);
};
export { Rt$Rows$head, Rt$Rows$tail, Rt$Rows$restate, Rt$Rows$dispose, Rt$Rows$forPosition, Rt$Rows$show, Rt$Rows$hide, Rt$Rows$forKeyed };
//# sourceMappingURL=Rows.mjs.map
