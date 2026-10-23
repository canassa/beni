// The Solid 2 twin of apps/pointer/Main.beni, for pointer.mjs (#557): a
// pointer handler eight elements above its target, a target eight elements
// deep with no handler above it, and a list of a thousand rows with a
// pointer handler on each. Solid delegates `pointerdown` and `pointermove`,
// and its walk defines `currentTarget` as the walk's node, so `moved` reads
// the box of the element that has the handler, as beni's extractor does.
import { createSignal, For } from "solid-js";
import { render } from "@solidjs/web";

const [x, setX] = createSignal(0);
const [pressed, setPressed] = createSignal(0);
const [rows, setRows] = createSignal([]);

const moved = (e) => {
  const r = e.currentTarget.getBoundingClientRect();
  setX(e.clientX - r.left);
};

render(
  () => (
    <main>
      <div id="pad" onPointerMove={moved}>
        <div><div><div><div><div><div><div><span id="leaf">x</span></div></div></div></div></div></div></div>
      </div>
      <div id="away">
        <div><div><div><div><div><div><div><span id="far">y</span></div></div></div></div></div></div></div>
      </div>
      <button id="make" onClick={() => setRows(Array.from({ length: 1000 }, (_, i) => i + 1))}>
        make
      </button>
      <ul>
        <For each={rows()}>{(i) => <li onPointerDown={() => setPressed(i)}>{i}</li>}</For>
      </ul>
    </main>
  ),
  document.body,
);
