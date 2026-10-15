import { Basics$min } from "../_core/Basics.mjs";
const List$Maybe$Nothing = { $: "Nothing", a: null };
const List$isTrie = (v$1) => !(v$1.T === undefined);
const List$reconsed = (a$1, x$2) => {
  const hc$3 = a$1.hc;
  const h$4 = a$1.h;
  return hc$3 < h$4.length && h$4[hc$3] === x$2;
};
const List$flatHead = (h$1, i$2, b$3, j$4) => {
  while (i$2 >= 0) {
    b$3[j$4] = h$1[i$2];
    i$2 = i$2 - 1;
    j$4 = j$4 + 1;
  }
  return j$4;
};
const List$copyTo = (x$1, i$2, b$3, j$4, stop$5) => {
  while (j$4 < stop$5) {
    b$3[j$4] = x$1[i$2];
    i$2 = i$2 + 1;
    j$4 = j$4 + 1;
  }
  return j$4;
};
const List$leafAt = (r$1, s$2, i$3) => {
  while (s$2 > 0) {
    r$1 = r$1[i$3 >>> s$2 & 31];
    s$2 = s$2 - 5;
  }
  return r$1;
};
const List$flatTree = (r$1, s$2, i$3, stop$4, b$5, j$6) => {
  while (i$3 < stop$4) {
    const $t$1 = i$3 + 32;
    j$6 = List$copyTo(List$leafAt(r$1, s$2, i$3), 0, b$5, j$6, j$6 + 32);
    i$3 = $t$1;
  }
  return j$6;
};
const List$triePlain = function() {
  const a$1 = this;
  const cached$2 = a$1.p;
  if (cached$2 === null) {
    const n$3 = a$1.length;
    const tr$4 = a$1.T;
    const off$5 = tr$4.off;
    const b$6 = new globalThis.Array(n$3);
    const j$7 = List$flatHead(a$1.h, a$1.hc - 1, b$6, 0);
    const k$8 = List$flatTree(tr$4.r, tr$4.s, off$5, off$5 + tr$4.tc, b$6, j$7);
    List$copyTo(a$1.t, 0, b$6, k$8, n$3);
    a$1.p = b$6;
    return b$6;
  } else {
    return cached$2;
  }
};
const List$header = (n$1, h$2, hc$3, tr$4, t$5) => ({ length: n$1, h: h$2, hc: hc$3, T: tr$4, t: t$5, p: null, $plain: List$triePlain });
const List$isPlain = globalThis.Array.isArray;
const List$base = (xs$1) => {
  const v$2 = xs$1;
  if (List$isPlain(v$2)) {
    return xs$1;
  } else {
    return v$2.o === undefined ? v$2.$plain() : v$2.b;
  }
};
const List$offset = (xs$1) => {
  const v$2 = xs$1;
  return List$isPlain(v$2) || v$2.o === undefined ? 0 : v$2.o;
};
const List$viewPlain = function() {
  const v$1 = this;
  const cached$2 = v$1.p;
  if (cached$2 === null) {
    const copied$3 = v$1.b.slice(v$1.o);
    v$1.p = copied$3;
    return copied$3;
  } else {
    return cached$2;
  }
};
const List$viewOf = (b$1, o$2) => ({ b: b$1, o: o$2, length: b$1.length - o$2, p: null, $plain: List$viewPlain });
const List$pushFrom = (b$1, i$2, c$3) => {
  while (i$2 < b$1.length) {
    c$3.push(b$1[i$2]);
    i$2 = i$2 + 1;
  }
  return c$3;
};
const List$cons = (x$1, xs$2) => {
  const t$3 = xs$2;
  if (List$isTrie(t$3) && List$reconsed(t$3, x$1)) {
    return List$header(xs$2.length + 1, t$3.h, t$3.hc + 1, t$3.T, t$3.t);
  } else {
    const b$4 = List$base(xs$2);
    const o$5 = List$offset(xs$2);
    if (o$5 > 0 && b$4[o$5 - 1] === x$1) {
      return o$5 === 1 ? b$4 : List$viewOf(b$4, o$5 - 1);
    } else {
      return xs$2.length < 32 ? List$pushFrom(b$4, o$5, [x$1]) : [x$1].concat(o$5 === 0 ? b$4 : b$4.slice(o$5));
    }
  }
};
const List$copy = (xs$1) => {
  const o$2 = List$offset(xs$1);
  return List$base(xs$1).slice(o$2, o$2 + xs$1.length);
};
const List$plainOf = (x$1) => List$isPlain(x$1) ? x$1 : x$1.$plain();
const List$fillTail = (t$1, b$2, i$3, stop$4) => {
  while (t$1.length < 32 && i$3 < stop$4) {
    t$1.push(b$2[i$3]);
    i$3 = i$3 + 1;
  }
  return i$3;
};
const List$treeOf = (r$1, s$2, off$3, tc$4) => ({ r: r$1, s: s$2, off: off$3, tc: tc$4 });
const List$padNull = (c$1, j$2) => {
  while (c$1.length < j$2) {
    c$1.push(null);
  }
};
const List$putLeaf = (x$1, s$2, i$3, leaf$4) => {
  const c$5 = x$1 === null ? [] : x$1.slice();
  const j$6 = i$3 >>> s$2 & 31;
  List$padNull(c$5, j$6);
  c$5[j$6] = s$2 === 5 ? leaf$4 : List$putLeaf(j$6 < c$5.length ? c$5[j$6] : null, s$2 - 5, i$3, leaf$4);
  return c$5;
};
const List$rightGrow = (r$1, s$2, off$3, tc$4, leaf$5) => {
  while (off$3 + tc$4 >= 2 ** (s$2 + 5)) {
    r$1 = [r$1];
    s$2 = s$2 + 5;
  }
  return List$treeOf(List$putLeaf(r$1, s$2, off$3 + tc$4, leaf$5), s$2, off$3, tc$4 + 32);
};
const List$treeRight = (tr$1, leaf$2) => {
  const tc$3 = tr$1.tc;
  return tc$3 === 0 ? List$rightGrow([], 5, 0, 0, leaf$2) : List$rightGrow(tr$1.r, tr$1.s, tr$1.off, tc$3, leaf$2);
};
const List$pushedLeaves = (a$1, n$2, tr$3, t$4, b$5, i$6, stop$7) => {
  while (i$6 < stop$7) {
    tr$3 = List$treeRight(tr$3, t$4);
    t$4 = b$5.slice(i$6, i$6 + 32);
    i$6 = i$6 + 32;
  }
  return List$header(n$2, a$1.h, a$1.hc, tr$3, t$4);
};
const List$triePushed = (a$1, b$2, o$3, m$4) => {
  const n$5 = a$1.length;
  const hc$6 = a$1.hc;
  const tr$7 = a$1.T;
  const c$8 = n$5 - hc$6 - tr$7.tc;
  if (c$8 < 32) {
    const t0$9 = a$1.t;
    const t$10 = t0$9.length === c$8 ? t0$9 : t0$9.slice(0, c$8);
    const i$11 = List$fillTail(t$10, b$2, o$3, o$3 + m$4);
    return List$pushedLeaves(a$1, n$5 + m$4, tr$7, t$10, b$2, i$11, o$3 + m$4);
  } else {
    return List$pushedLeaves(a$1, n$5 + m$4, tr$7, a$1.t, b$2, o$3, o$3 + m$4);
  }
};
const List$noTree = { r: [], s: 5, off: 0, tc: 0 };
const List$chunks = (x$1, i$2, stop$3, out$4) => {
  while (i$2 < stop$3) {
    out$4.push(x$1.slice(i$2, i$2 + 32));
    i$2 = i$2 + 32;
  }
  return out$4;
};
const List$fromLevels = (b$1, o$2, n$3, full$4, x$5, s$6) => {
  while (x$5.length > 32) {
    x$5 = List$chunks(x$5, 0, x$5.length, []);
    s$6 = s$6 + 5;
  }
  return List$header(n$3, [], 0, List$treeOf(x$5, s$6, 0, full$4), b$1.slice(o$2 + full$4));
};
const List$fromPlain = (b$1, o$2) => {
  const n$3 = b$1.length - o$2;
  const full$4 = n$3 - 1 >>> 5 << 5;
  return full$4 === 0 ? List$header(n$3, [], 0, List$noTree, b$1.slice(o$2)) : List$fromLevels(b$1, o$2, n$3, full$4, List$chunks(b$1, o$2, o$2 + full$4, []), 5);
};
const List$append = (xs$1, ys$2) => {
  const n$3 = xs$1.length;
  const m$4 = ys$2.length;
  if (m$4 === 0) {
    return List$copy(xs$1);
  } else {
    if (n$3 === 0) {
      return List$copy(ys$2);
    } else {
      const x$5 = xs$1;
      const trie$6 = List$isTrie(x$5);
      return (trie$6 ? m$4 >= n$3 : n$3 < 32 || m$4 >= 32) ? List$plainOf(x$5).concat(List$plainOf(ys$2)) : List$triePushed(trie$6 ? x$5 : List$fromPlain(List$base(xs$1), List$offset(xs$1)), List$base(ys$2), List$offset(ys$2), m$4);
    }
  }
};
const List$eqFrom = ($m$0, a$1, i$2, b$3, j$4) => {
  while (i$2 < a$1.length) {
    if ($m$0(a$1[i$2], b$3[j$4])) {
      i$2 = i$2 + 1;
      j$4 = j$4 + 1;
    } else {
      return false;
    }
  }
  return true;
};
const List$eq = ($m$0, xs$1, ys$2) => xs$1.length === ys$2.length && List$eqFrom($m$0, List$base(xs$1), List$offset(xs$1), List$base(ys$2), List$offset(ys$2));
const List$trieGet = (a$1, i$2) => {
  const hc$3 = a$1.hc;
  if (i$2 < hc$3) {
    return a$1.h[hc$3 - 1 - i$2];
  } else {
    const tr$4 = a$1.T;
    const j$5 = i$2 - hc$3;
    const tc$6 = tr$4.tc;
    if (j$5 >= tc$6) {
      return a$1.t[j$5 - tc$6];
    } else {
      const k$7 = j$5 + tr$4.off;
      return List$leafAt(tr$4.r, tr$4.s, k$7)[k$7 & 31];
    }
  }
};
const List$unsafeGet = (xs$1, i$2) => {
  const v$3 = xs$1;
  if (List$isPlain(v$3)) {
    return v$3[i$2];
  } else {
    return v$3.o === undefined ? List$trieGet(v$3, i$2) : v$3.b[v$3.o + i$2];
  }
};
const List$trieDrop = (a$1, k$2) => {
  const len$3 = a$1.length;
  const hc$4 = a$1.hc;
  if (k$2 <= hc$4) {
    return List$header(len$3 - k$2, a$1.h, hc$4 - k$2, a$1.T, a$1.t);
  } else {
    const tr$5 = a$1.T;
    const k2$6 = k$2 - hc$4;
    const tc$7 = tr$5.tc;
    if (k2$6 >= tc$7) {
      return a$1.t.slice(k2$6 - tc$7, len$3 - hc$4 - tc$7);
    } else {
      const r$8 = tr$5.r;
      const s$9 = tr$5.s;
      const i$10 = tr$5.off + (k2$6 & 0 - 32);
      const front$11 = List$leafAt(r$8, s$9, i$10).slice(k2$6 & 31).reverse();
      return List$header(len$3 - k$2, front$11, 32 - (k2$6 & 31), List$treeOf(r$8, s$9, i$10 + 32, tc$7 - (k2$6 & 0 - 32) - 32), a$1.t);
    }
  }
};
const List$view = (xs$1, k$2) => {
  if (k$2 === 0) {
    return xs$1;
  } else {
    if (k$2 >= xs$1.length) {
      return [];
    } else {
      return List$isTrie(xs$1) ? List$trieDrop(xs$1, k$2) : List$viewOf(List$base(xs$1), List$offset(xs$1) + k$2);
    }
  }
};
const List$builder = (n$1) => new globalThis.Array(n$1 > 0 ? n$1 : 0);
const List$done = (b$1, n$2) => {
  const v$3 = b$1;
  if (v$3.length !== n$2) {
    v$3.length = n$2;
  }
  return v$3;
};
const List$putAll = (b$1, j$2, a$3, i$4, stop$5) => {
  while (i$4 < stop$5) {
    b$1[j$2] = a$3[i$4];
    b$1 = b$1;
    j$2 = j$2 + 1;
    i$4 = i$4 + 1;
  }
  return b$1;
};
const List$close = (b$1, v$2) => {
  const n$3 = b$1.length;
  return n$3 === 0 ? v$2 : List$done(List$putAll(b$1, n$3, List$base(v$2), List$offset(v$2), List$offset(v$2) + v$2.length), n$3 + v$2.length);
};
const List$foldlFrom = (a$1, i$2, stop$3, acc$4, func$5) => {
  while (i$2 < stop$3) {
    const $t$2 = i$2 + 1;
    acc$4 = func$5(a$1[i$2], acc$4);
    i$2 = $t$2;
  }
  return acc$4;
};
const List$foldl = (xs$1, acc$2, func$3) => List$foldlFrom(List$base(xs$1), List$offset(xs$1), List$offset(xs$1) + xs$1.length, acc$2, func$3);
const List$foldrFrom = (a$1, o$2, i$3, acc$4, func$5) => {
  while (!(i$3 < o$2)) {
    const $t$3 = i$3 - 1;
    acc$4 = func$5(a$1[i$3], acc$4);
    i$3 = $t$3;
  }
  return acc$4;
};
const List$foldr = (xs$1, acc$2, func$3) => List$foldrFrom(List$base(xs$1), List$offset(xs$1), List$offset(xs$1) + xs$1.length - 1, acc$2, func$3);
const List$mapHelp = (a$1, o$2, i$3, n$4, func$5, b$6) => {
  while (i$3 < n$4) {
    const $t$4 = i$3 + 1;
    b$6[i$3] = func$5(a$1[o$2 + i$3]);
    i$3 = $t$4;
    b$6 = b$6;
  }
  return List$done(b$6, n$4);
};
const List$map = (xs$1, func$2) => List$mapHelp(List$base(xs$1), List$offset(xs$1), 0, xs$1.length, func$2, List$builder(xs$1.length));
const List$filterHelp = (a$1, o$2, i$3, n$4, isGood$5, b$6, j$7) => {
  while (i$3 < n$4) {
    const x$8 = a$1[o$2 + i$3];
    if (isGood$5(x$8)) {
      const $t$5 = i$3 + 1;
      b$6[j$7] = x$8;
      i$3 = $t$5;
      b$6 = b$6;
      j$7 = j$7 + 1;
    } else {
      i$3 = i$3 + 1;
      b$6 = b$6;
      j$7 = j$7;
    }
  }
  return List$done(b$6, j$7);
};
const List$filter = (xs$1, isGood$2) => List$filterHelp(List$base(xs$1), List$offset(xs$1), 0, xs$1.length, isGood$2, List$builder(xs$1.length), 0);
const List$filterMapHelp = (a$1, o$2, i$3, n$4, func$5, b$6, j$7) => {
  while (i$3 < n$4) {
    const $t$6 = func$5(a$1[o$2 + i$3]);
    if ($t$6.$ === "Just") {
      const y$8 = $t$6.a;
      const $t$7 = i$3 + 1;
      b$6[j$7] = y$8;
      i$3 = $t$7;
      b$6 = b$6;
      j$7 = j$7 + 1;
    } else {
      i$3 = i$3 + 1;
      b$6 = b$6;
      j$7 = j$7;
    }
  }
  return List$done(b$6, j$7);
};
const List$filterMap = (xs$1, func$2) => List$filterMapHelp(List$base(xs$1), List$offset(xs$1), 0, xs$1.length, func$2, List$builder(xs$1.length), 0);
const List$reverseHelp = (a$1, top$2, i$3, n$4, b$5) => {
  while (i$3 < n$4) {
    const $t$8 = i$3 + 1;
    b$5[i$3] = a$1[top$2 - i$3];
    i$3 = $t$8;
    b$5 = b$5;
  }
  return List$done(b$5, n$4);
};
const List$reverse = (xs$1) => List$reverseHelp(List$base(xs$1), List$offset(xs$1) + xs$1.length - 1, 0, xs$1.length, List$builder(xs$1.length));
const List$totalFrom = (a$1, i$2, n$3) => {
  while (i$2 < a$1.length) {
    n$3 = n$3 + a$1[i$2].length;
    i$2 = i$2 + 1;
  }
  return n$3;
};
const List$concatFrom = (a$1, i$2, b$3, j$4) => {
  while (i$2 < a$1.length) {
    const l$5 = a$1[i$2];
    i$2 = i$2 + 1;
    b$3 = List$putAll(b$3, j$4, List$base(l$5), List$offset(l$5), List$offset(l$5) + l$5.length);
    j$4 = j$4 + l$5.length;
  }
  return b$3;
};
const List$concat = (ls$1) => {
  const a$2 = List$base(ls$1);
  const o$3 = List$offset(ls$1);
  const n$4 = List$totalFrom(a$2, o$3, 0);
  return List$done(List$concatFrom(a$2, o$3, List$builder(n$4), 0), n$4);
};
const List$concatMap = (xs$1, func$2) => List$concat(List$map(xs$1, func$2));
const List$get = (xs$1, i$2) => 0 <= i$2 && i$2 < xs$1.length ? { $: "Just", a: List$unsafeGet(xs$1, i$2) } : List$Maybe$Nothing;
const List$head = (xs$1) => List$get(xs$1, 0);
const List$drop = (xs$1, n$2) => n$2 <= 0 ? xs$1 : List$view(xs$1, Basics$min(n$2, xs$1.length));
export { List$cons, List$append, List$eq, List$copy, List$foldl, List$foldr, List$map, List$filter, List$filterMap, List$reverse, List$concat, List$concatMap, List$head, List$drop, List$get, List$unsafeGet, List$view, List$base, List$offset, List$close };
//# sourceMappingURL=List.mjs.map
