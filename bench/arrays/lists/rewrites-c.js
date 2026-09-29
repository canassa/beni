// Candidate C of research/38 §16: candidate B plus the rewrites a compiler could honestly make,
// applied BY HAND to beni's output, one declaration at a time. lists.mjs replaces each named
// `const` of the compiled module with the text below (and fails if a name is missing), after the
// B rewrite of the list syntax. Every rewrite names the rule that licenses it; each rule needs only
// the declaration itself, the module it is in, or one fixed `core/List` function — never the whole
// program. What is NOT here is as important: the TEA model's list, `recordFold` and
// `partitionFold` are left as B compiles them, because no rule below proves their accumulators
// unique (§16.3).
//
//   R1  local builder. A self-tail-recursive helper's List parameter `acc` that every call site
//       outside the loop passes as `[]` (the helper is module-private, so all its call sites are in
//       the module), and that the loop uses only as the tail of one `e :: acc` feeding its own slot,
//       or at an exit as `acc` / `List.reverse acc` — is unique. It becomes a JS array the loop
//       owns, stored back to front: `e :: acc` is `acc.push(e)`, `List.reverse acc` is the array,
//       and a bare `acc` is the array reversed once. The same holds for `acc ++ [ e ]`, stored
//       front to back.
//   R2  tail recursion modulo cons. A self-call that is the tail of a `::` in return position,
//       `e :: f rest`, becomes a push into a fresh builder and a jump back to the top; a base case
//       `ys` appends ys's elements and returns the builder. No uniqueness is needed: the builder is
//       new and private to this call. (It would also end the cons list's stack overflows.)
//   R3  scalar view. A List parameter of a loop that is only matched, and whose tail flows only
//       back into the same parameter, is carried as (backing array, offset); `x :: rest` is
//       `a[o]` and `o + 1`, with no view allocated.
//   R4  one fixed core function inlined. `List.foldl xs z (\x acc -> …)` / `List.foldr …` with a
//       literal lambda is core's 5-line loop at the call site, after which R1 applies to the
//       lambda's accumulator if it qualifies.
//   R5  re-cons of a match. `h :: t`, where the case just matched a value v as `h :: t`, is v.

export const REWRITES = {
  'Recur.mjs': {
    // R2 + R3
    Recur$mapRec: `const Recur$mapRec = (xs$1, f$2) => {
  $span(xs$1);
  const a = $SA, n = a.length, out = [];
  for (let o = $SO; o < n; o++) out.push(f$2(a[o]));
  return out;
};`,
    // R2 + R3 (the dropping branch was already a loop)
    Recur$filterRec: `const Recur$filterRec = (xs$1, keep$2) => {
  $span(xs$1);
  const a = $SA, n = a.length, out = [];
  for (let o = $SO; o < n; o++) { const x = a[o]; if (keep$2(x)) out.push(x); }
  return out;
};`,
    // R1 (the only caller, mapAcc, passes []) + R3
    Recur$mapAccHelp: `const Recur$mapAccHelp = (xs$1, f$2, _nil) => {
  $span(xs$1);
  const a = $SA, n = a.length, acc = [];
  for (let o = $SO; o < n; o++) acc.push(f$2(a[o]));
  return $fromBuilder(acc);
};`,
    // R1 + R3
    Recur$filterAccHelp: `const Recur$filterAccHelp = (xs$1, keep$2, _nil) => {
  $span(xs$1);
  const a = $SA, n = a.length, acc = [];
  for (let o = $SO; o < n; o++) { const x = a[o]; if (keep$2(x)) acc.push(x); }
  return $fromBuilder(acc);
};`,
    // R3
    Recur$sumHelp: `const Recur$sumHelp = (xs$1, acc$2) => {
  $span(xs$1);
  const a = $SA, n = a.length;
  for (let o = $SO; o < n; o++) acc$2 = Basics$add(acc$2, a[o]);
  return acc$2;
};`,
    // R2 + R3
    Recur$takeWhile: `const Recur$takeWhile = (xs$1, keep$2) => {
  $span(xs$1);
  const a = $SA, n = a.length, out = [];
  for (let o = $SO; o < n; o++) { const x = a[o]; if (!keep$2(x)) break; out.push(x); }
  return out;
};`,
    // R5 (\`b :: rest\` is the tail just matched) + R2 + R3
    Recur$pairwise: `const Recur$pairwise = (xs$1) => {
  $span(xs$1);
  const a = $SA, n = a.length, out = [];
  for (let o = $SO; o + 1 < n; o++) out.push({ a: a[o], b: a[o + 1] });
  return out;
};`,
    // R1 on both accumulators (the only caller, mergeSort, passes [] []) + R3; the tuple returns
    // bare accumulators, so each is reversed once
    Recur$split: `const Recur$split = (xs$1, _l, _r) => {
  $span(xs$1);
  const a = $SA, n = a.length;
  let left = [], right = [];
  for (let o = $SO; o < n; o++) { const t = left; t.push(a[o]); left = right; right = t; }
  return { a: $fromBuilderRev(left), b: $fromBuilderRev(right) };
};`,
    // R5 (\`y :: yt\` and \`x :: xt\` are the lists just matched) + R2 + R3 on both lists
    Recur$merge: `const Recur$merge = (xs$1, ys$2) => {
  $span(xs$1);
  const a = $SA, n = a.length;
  let i = $SO;
  $span(ys$2);
  const b = $SA, m = b.length;
  let j = $SO;
  const out = [];
  while (true) {
    if (i >= n) { for (; j < m; j++) out.push(b[j]); return out; }
    if (j >= m) { for (; i < n; i++) out.push(a[i]); return out; }
    const x = a[i], y = b[j];
    if (x <= y) { out.push(x); i++; } else { out.push(y); j++; }
  }
};`,
  },
  'Lib.mjs': {
    // R4 + R1 (foldr visits back to front, so the builder holds the result front to back reversed)
    Lib$foldrBuild: `const Lib$foldrBuild = (xs$1) => {
  $span(xs$1);
  const a = $SA, o = $SO, acc = [];
  for (let k = a.length - 1; k >= o; k--) acc.push(Basics$mul(a[k], 2));
  return $fromBuilderRev(acc);
};`,
    // R4 + R1 (\`acc ++ [ x ]\` on the unique accumulator is a push, front to back)
    Lib$appendLoop: `const Lib$appendLoop = (xs$1) => {
  $span(xs$1);
  const a = $SA, n = a.length, acc = [];
  for (let o = $SO; o < n; o++) acc.push(a[o]);
  return acc;
};`,
    // R4 + R1 (\`List.reverse\` of the back-to-front builder is the builder)
    Lib$prependFold: `const Lib$prependFold = (xs$1) => {
  $span(xs$1);
  const a = $SA, n = a.length, acc = [];
  for (let o = $SO; o < n; o++) acc.push(Basics$mul(a[o], 2));
  return $fromBuilder(acc);
};`,
  },
};
