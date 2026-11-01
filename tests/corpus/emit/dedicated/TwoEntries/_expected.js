import { Page$initializer, Page$text, Page$button, Page$program } from "./_platform/Page.mjs";
import { Worker$open, Worker$receive, Worker$send } from "./_platform/Worker.mjs";
const TwoEntries$pageOnly = Page$initializer("page-only");
const TwoEntries$worker = { id: "f075e64ddd0fa55e", url: new globalThis.URL("./_workers/f075e64ddd0fa55e/_main.mjs", import.meta.url).href };
const TwoEntries$selected = { id: "f075e64ddd0fa55e", url: new globalThis.URL("./_workers/f075e64ddd0fa55e/_main.mjs", import.meta.url).href };
const TwoEntries$launch = ($p$1) => {
  const $t$2 = Worker$open(TwoEntries$pageOnly === "page-only" ? TwoEntries$selected : { id: "f075e64ddd0fa55e", url: new globalThis.URL("./_workers/f075e64ddd0fa55e/_main.mjs", import.meta.url).href });
  if ($t$2.$ === "Ok") {
    const handle$1 = $t$2.a;
    Worker$receive(handle$1, Page$text);
    return Worker$send(handle$1, "ping");
  } else {
    return Page$text("open failed");
  }
};
const TwoEntries$start = ($p$1) => {
  Page$text(TwoEntries$pageOnly);
  return Page$button(TwoEntries$launch);
};
const TwoEntries$main = Page$program(TwoEntries$start);
export { TwoEntries$main };
//# sourceMappingURL=TwoEntries.mjs.map
