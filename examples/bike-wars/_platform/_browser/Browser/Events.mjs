import { Listen$on } from "../../../_platform/_browser/Listen.mjs";
import { Sub$on } from "../../../_platform/_browser/Sub.mjs";
import { Task$fromHost } from "../../../_core/Task.mjs";
import { Basics$toFloat } from "../../../_core/Basics.mjs";
const Browser$Events$FrameKey$$order = { AnimationFrame: 0, AnimationFrameDelta: 1 };
const Browser$Events$Key$$order = { Resize: 0, VisibilityChange: 1, KeyDown: 2, KeyUp: 3, KeyPress: 4 };
const Browser$Events$FrameKey$$compare = ($x, $y) => {
  const $a = Browser$Events$FrameKey$$order[$x];
  const $b = Browser$Events$FrameKey$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const Browser$Events$Key$$compare = ($x, $y) => {
  const $a = Browser$Events$Key$$order[$x];
  const $b = Browser$Events$Key$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const Browser$Events$event = (v$1) => v$1;
const Browser$Events$keys = (name$1, send$2) => Listen$on("document", name$1, Browser$Events$event, send$2);
const Browser$Events$onKeyDown = (tag$1) => Sub$on(Browser$Events$Key$$compare, "platform:Browser.Events.Key", "KeyDown", ($p$1) => Browser$Events$keys("keydown", $p$1), tag$1);
const Browser$Events$frameClock = [new globalThis.Set(), null, 0];
const Browser$Events$wall = () => globalThis.Date.now();
const Browser$Events$tick = () => Task$fromHost(() => {
  const now$1 = Browser$Events$wall();
  const last$2 = Browser$Events$frameClock[2];
  Browser$Events$ask();
  Browser$Events$frameClock[2] = now$1;
  for (const f$3 of globalThis.Array.from(Browser$Events$frameClock[0])) {
    f$3(now$1, last$2);
  }
  return null;
});
const Browser$Events$ask = () => {
  Browser$Events$frameClock[1] = globalThis.requestAnimationFrame(($p$2) => Browser$Events$tick());
};
const Browser$Events$frames = (read$1, send$2) => {
  const listeners$3 = Browser$Events$frameClock[0];
  if (Browser$Events$frameClock[1] === null) {
    Browser$Events$frameClock[2] = Browser$Events$wall();
    Browser$Events$ask();
  }
  const f$4 = (now$5, last$6) => send$2(read$1(now$5, last$6));
  listeners$3.add(f$4);
  return () => {
    listeners$3.delete(f$4);
    if (listeners$3.size === 0) {
      globalThis.cancelAnimationFrame(Browser$Events$frameClock[1]);
      Browser$Events$frameClock[1] = null;
      return null;
    } else {
      return null;
    }
  };
};
const Browser$Events$delta = (now$1, last$2) => Basics$toFloat(now$1 - last$2);
const Browser$Events$onAnimationFrameDelta = (tag$1) => Sub$on(Browser$Events$FrameKey$$compare, "platform:Browser.Events.FrameKey", "AnimationFrameDelta", ($p$3) => Browser$Events$frames(Browser$Events$delta, $p$3), tag$1);
export { Browser$Events$FrameKey$$compare, Browser$Events$Key$$compare, Browser$Events$onKeyDown, Browser$Events$onAnimationFrameDelta };
//# sourceMappingURL=Events.mjs.map
