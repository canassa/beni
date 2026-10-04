// Sweep 8b, rows holding a helper: `live.mjs`'s page with each row's input
// replaced by plain text, so a row holds a helper's markup and nothing
// live. A render that skips the rows should visit none of them.

import * as live from "./live.mjs";

const swap = (text, from, to) => {
  if (!text.includes(from)) throw new Error(`live-helper: no ${from}`);
  return text.replace(from, to).replace("live rows,", "rows holding a helper,");
};

export const beni = (n) => swap(live.beni(n), "<input value={row.label} onInput={Edit row.id _} />", "{row.label}");
export const solid = (v, n) => swap(live.solid(v, n), "<input value={row.label()} onInput={(e) => row.setLabel(e.target.value)} />", "{row.label()}");
export const p2 = live.p2;
export const vanilla = live.vanilla;
