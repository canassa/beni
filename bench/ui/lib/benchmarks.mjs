// A port of js-framework-benchmark's `benchmarksWebdriverCDP.ts` and the
// throttling factors of `benchmarksCommon.ts` (commit 652198560d0c): the
// nine CPU benchmarks, their warm-ups, the element clicked and the
// post-condition that says the operation finished.

const x = (path) => `document.evaluate(${JSON.stringify(path)}, document, null, 9, null).singleNodeValue`;
const byId = (id) => `document.getElementById(${JSON.stringify(id)})`;
const textContains = (path, text) => `(() => { const n = ${x(path)}; return n !== null && n.textContent.includes(${JSON.stringify(text)}); })()`;
const located = (path) => `(${x(path)} !== null)`;
const notLocated = (path) => `(${x(path)} === null)`;
const classContains = (path, name) => `(() => { const n = ${x(path)}; return n !== null && n.classList.contains(${JSON.stringify(name)}); })()`;

// `page` is lib/cdp.mjs's Page. Each benchmark: `init(page)` warms up,
// `target` is the element the measured click lands on, and `done` the
// expression that must hold after it.
export const benchmarks = [
  {
    id: "01_run1k",
    label: "create 1k",
    throttle: 1,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      for (let i = 0; i < 5; i++) {
        await p.click(byId("run"));
        await p.waitFor(textContains("//tbody/tr[1]/td[1]", (i * 1000 + 1).toFixed()));
        await p.click(byId("clear"));
        await p.waitFor(notLocated("//tbody/tr[1]"));
      }
    },
    target: byId("run"),
    done: textContains("//tbody/tr[1]/td[1]", (5 * 1000 + 1).toFixed()),
  },
  {
    id: "02_replace1k",
    label: "replace 1k",
    throttle: 1,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      for (let i = 0; i < 5; i++) {
        await p.click(byId("run"));
        await p.waitFor(textContains("//tbody/tr[1]/td[1]", (i * 1000 + 1).toFixed()));
      }
    },
    target: byId("run"),
    done: textContains("//tbody/tr[1]/td[1]", `${5 * 1000 + 1}`),
  },
  {
    id: "03_update10th1k_x16",
    label: "update 10th",
    throttle: 4,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      await p.click(byId("run"));
      await p.waitFor(located("//tbody/tr[1000]/td[2]/a"));
      for (let i = 0; i < 3; i++) {
        await p.click(byId("update"));
        await p.waitFor(textContains("//tbody/tr[991]/td[2]/a", " !!!".repeat(i + 1)));
      }
    },
    target: byId("update"),
    done: textContains("//tbody/tr[991]/td[2]/a", " !!!".repeat(4)),
  },
  {
    id: "04_select1k",
    label: "select",
    throttle: 4,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      await p.click(byId("run"));
      await p.waitFor(located("//tbody/tr[1]/td[2]/a"));
    },
    target: x("//tbody/tr[2]/td[2]/a"),
    done: classContains("//tbody/tr[2]", "danger"),
  },
  {
    id: "05_swap1k",
    label: "swap",
    throttle: 4,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      await p.click(byId("run"));
      await p.waitFor(located("//tbody/tr[1]/td[1]"));
      for (let i = 0; i <= 5; i++) {
        await p.click(byId("swaprows"));
        await p.waitFor(textContains("//tbody/tr[999]/td[1]", i % 2 === 0 ? "2" : "999"));
      }
    },
    target: byId("swaprows"),
    // warmupCount 5 is odd: row 999 shows 2 again and row 2 shows 999.
    done: `(${textContains("//tbody/tr[999]/td[1]", "2")} && ${textContains("//tbody/tr[2]/td[1]", "999")})`,
  },
  {
    id: "06_remove-one-1k",
    label: "remove",
    throttle: 2,
    async init(p) {
      const skip = 4;
      const warm = 5;
      await p.waitFor(`${byId("run")} !== null`);
      await p.click(byId("run"));
      await p.waitFor(located("//tbody/tr[1000]/td[1]"));
      for (let i = 0; i < warm; i++) {
        const row = warm - i + skip;
        await p.waitFor(textContains(`//tbody/tr[${row}]/td[1]`, row.toString()));
        await p.click(x(`//tbody/tr[${row}]/td[3]/a/span[1]`));
        await p.waitFor(textContains(`//tbody/tr[${row}]/td[1]`, `${skip + warm + 1}`));
      }
      await p.waitFor(textContains(`//tbody/tr[${skip + 1}]/td[1]`, `${skip + warm + 1}`));
      await p.waitFor(textContains(`//tbody/tr[${skip}]/td[1]`, `${skip}`));
      await p.waitFor(textContains(`//tbody/tr[${skip + 2}]/td[1]`, `${skip + warm + 2}`));
      await p.click(x(`//tbody/tr[${skip + 2}]/td[3]/a/span[1]`));
      await p.waitFor(textContains(`//tbody/tr[${skip + 2}]/td[1]`, `${skip + warm + 3}`));
    },
    target: x("//tbody/tr[4]/td[3]/a/span[1]"),
    done: textContains("//tbody/tr[4]/td[1]", `${4 + 5 + 1}`),
  },
  {
    id: "07_create10k",
    label: "create 10k",
    throttle: 1,
    settle: 4000,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      for (let i = 0; i < 5; i++) {
        await p.click(byId("run"));
        await p.waitFor(textContains("//tbody/tr[1]/td[1]", (i * 1000 + 1).toFixed()));
        await p.click(byId("clear"));
        await p.waitFor(notLocated("//tbody/tr[1]"));
      }
    },
    target: byId("runlots"),
    done: located("//tbody/tr[10000]/td[2]/a"),
  },
  {
    id: "08_create1k-after1k_x2",
    label: "append 1k",
    throttle: 1,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      for (let i = 0; i < 5; i++) {
        await p.click(byId("run"));
        await p.waitFor(textContains("//tbody/tr[1]/td[1]", (i * 1000 + 1).toFixed()));
        await p.click(byId("clear"));
        await p.waitFor(notLocated("//tbody/tr[1]"));
      }
      await p.click(byId("run"));
      await p.waitFor(located("//tbody/tr[1000]/td[2]/a"));
    },
    target: byId("add"),
    done: located("//tbody/tr[2000]/td[2]/a"),
  },
  {
    id: "09_clear1k_x8",
    label: "clear",
    throttle: 4,
    async init(p) {
      await p.waitFor(`${byId("run")} !== null`);
      for (let i = 0; i < 5; i++) {
        await p.click(byId("run"));
        await p.waitFor(located("//tbody/tr[1000]/td[2]/a"));
        await p.click(byId("clear"));
        await p.waitFor(notLocated("//tbody/tr[1]"));
      }
      await p.click(byId("run"));
      await p.waitFor(located("//tbody/tr[1000]/td[2]/a"));
    },
    target: byId("clear"),
    done: notLocated("//tbody/tr[1]"),
  },
];
