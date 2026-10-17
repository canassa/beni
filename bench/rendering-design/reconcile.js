// Unmodified reconcileArrays from @solidjs/web 2.0.0-rc.9.
// MIT, Copyright (c) 2016-2025 Ryan Carniato. See THIRD_PARTY_LICENSES.md.
const $$SLOT=Symbol("slot");
function reconcileArrays(parentNode, a, b, marker) {
  let bLength = b.length,
    aEnd = a.length,
    bEnd = bLength,
    aStart = 0,
    bStart = 0,
    tail = a[aEnd - 1],
    tailTag = tail[$$SLOT],
    after = tail.parentNode === parentNode && (!tailTag || tailTag === marker) ? tail.nextSibling : marker || null,
    map = null,
    anchor,
    anchorTag;
  const isLive = n => {
    if (!n) return false;
    const tag = n[$$SLOT];
    return n.parentNode === parentNode && (!tag || tag === marker);
  };
  while (aStart < aEnd || bStart < bEnd) {
    if (a[aStart] === b[bStart] && isLive(a[aStart])) {
      aStart++;
      bStart++;
      continue;
    }
    while (a[aEnd - 1] === b[bEnd - 1] && isLive(a[aEnd - 1])) {
      aEnd--;
      bEnd--;
    }
    if (aEnd === aStart) {
      let node;
      if (bEnd < bLength) {
        if (bStart) {
          const prev = b[bStart - 1];
          const prevTag = prev[$$SLOT];
          node = prev.parentNode === parentNode && (!prevTag || prevTag === marker) ? prev.nextSibling : after;
        } else node = b[bEnd - bStart];
      } else node = after;
      while (bStart < bEnd) {
        const n = b[bStart++];
        parentNode.insertBefore(n, node);
        if (marker) n[$$SLOT] = marker;
      }
    } else if (bEnd === bStart) {
      while (aStart < aEnd) {
        const n = a[aStart++];
        if (!map || !map.has(n)) {
          const tag = n[$$SLOT];
          if (n.parentNode === parentNode && (!tag || tag === marker)) n.remove();
        }
      }
    } else if ((anchor = a[aStart]) === b[bEnd - 1] && b[bStart] === a[aEnd - 1] && anchor.parentNode === parentNode && (!(anchorTag = anchor[$$SLOT]) || anchorTag === marker)) {
      if (marker) {
        do {
          const n = a[--aEnd];
          parentNode.insertBefore(n, anchor);
          n[$$SLOT] = marker;
          bStart++;
          if (aStart >= aEnd - 1 || bStart >= bEnd) break;
        } while (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]);
      } else {
        do {
          parentNode.insertBefore(a[--aEnd], anchor);
          bStart++;
          if (aStart >= aEnd - 1 || bStart >= bEnd) break;
        } while (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]);
      }
    } else {
      if (!map) {
        map = new Map();
        let i = bStart;
        while (i < bEnd) map.set(b[i], i++);
      }
      const index = map.get(a[aStart]);
      if (index != null) {
        if (bStart < index && index < bEnd) {
          let i = aStart,
            sequence = 1,
            t;
          while (++i < aEnd && i < bEnd) {
            if ((t = map.get(a[i])) == null || t !== index + sequence) break;
            sequence++;
          }
          if (sequence > index - bStart) {
            const head = a[aStart];
            const headTag = head[$$SLOT];
            const node = head.parentNode === parentNode && (!headTag || headTag === marker) ? head : after;
            while (bStart < index) {
              const n = b[bStart++];
              parentNode.insertBefore(n, node);
              if (marker) n[$$SLOT] = marker;
            }
          } else {
            const oldNode = a[aStart++];
            const newNode = b[bStart++];
            const oldTag = oldNode[$$SLOT];
            if (oldNode.parentNode === parentNode && (!oldTag || oldTag === marker)) {
              parentNode.replaceChild(newNode, oldNode);
            } else {
              parentNode.insertBefore(newNode, after);
            }
            if (marker) newNode[$$SLOT] = marker;
          }
        } else aStart++;
      } else {
        const n = a[aStart++];
        const nTag = n[$$SLOT];
        if (n.parentNode === parentNode && (!nTag || nTag === marker)) n.remove();
      }
    }
  }
}
