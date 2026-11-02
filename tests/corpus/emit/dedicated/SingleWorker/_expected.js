import { Page$initializer, Page$text, Page$button, Page$program } from "./_platform/Page.mjs";
import { Worker$open, Worker$receive, Worker$send } from "./_platform/Worker.mjs";
const SingleWorker$pageOnly = Page$initializer("page-only");
const SingleWorker$worker = { $wire: [[[0, 2], [1, 3]], [0, 0, 0, 0, 0, 0]], id: "1c1928caf485efcb", url: new globalThis.URL("./_workers/1c1928caf485efcb/_main.mjs", import.meta.url).href };
const SingleWorker$selected = { $wire: [[[0, 2], [1, 3]], [0, 0, 0, 0, 0, 0]], id: "1c1928caf485efcb", url: new globalThis.URL("./_workers/1c1928caf485efcb/_main.mjs", import.meta.url).href };
const SingleWorker$launch = ($p$1) => {
  const $t$2 = Worker$open(SingleWorker$pageOnly === "page-only" ? SingleWorker$selected : { $wire: [[[0, 2], [1, 3]], [0, 0, 0, 0, 0, 0]], id: "1c1928caf485efcb", url: new globalThis.URL("./_workers/1c1928caf485efcb/_main.mjs", import.meta.url).href });
  if ($t$2.$ === "Ok") {
    const handle$1 = $t$2.a;
    Worker$receive(handle$1, Page$text);
    return Worker$send(handle$1, "ping");
  } else {
    return Page$text("open failed");
  }
};
const SingleWorker$start = ($p$1) => {
  Page$text(SingleWorker$pageOnly);
  return Page$button(SingleWorker$launch);
};
const SingleWorker$main = Page$program(SingleWorker$start);
export { SingleWorker$main };
//# sourceMappingURL=SingleWorker.mjs.map
