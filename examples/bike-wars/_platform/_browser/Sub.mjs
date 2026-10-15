import { List$append, List$foldr } from "../../_core/List.mjs";
import { Hosted$key, Hosted$hook } from "../../_platform/_browser/Hosted.mjs";
const Sub$None = { $: "None", a: null };
const Sub$both = (sub$1, rest$2) => {
  if (sub$1.$ === "None") {
    return rest$2;
  } else {
    const list$3 = sub$1.a;
    if (rest$2.$ === "None") {
      return { $: "Listen", a: list$3 };
    } else {
      const more$4 = rest$2.a;
      return { $: "Listen", a: List$append([], List$append(list$3, more$4)) };
    }
  }
};
const Sub$batch = (subs$1) => List$foldr(subs$1, Sub$None, Sub$both);
const Sub$on = ($m$0, $m$1, k$1, start$2, tag$3) => ({ $: "Listen", a: [{ a: Hosted$key($m$0, $m$1, k$1), b: "Hears", c: Hosted$hook(start$2, tag$3) }] });
export { Sub$batch, Sub$on };
//# sourceMappingURL=Sub.mjs.map
