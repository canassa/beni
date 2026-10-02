// The sibling JavaScript of `Requests.beni`: each scenario calls `fetch`
// and logs the answer — status, `ok`, status text, `url`, headers and body —
// or the rejection's name. A rejection a scenario does not expect is thrown
// on (CLAUDE.md rule 9).

const shown = (r) =>
  `${r.status} ${r.ok} ${JSON.stringify(r.statusText)} ${r.url.replace(globalThis.location.origin, "")} ${JSON.stringify([...r.headers].map(([n, v]) => [n.toLowerCase(), v]).sort())}`;

const withText = (label) => (r) => r.text().then((text) => console.log(`${label}: ${shown(r)} ${JSON.stringify(text)}`));

const expecting = (label, test) => (e) => {
  if (!test(e)) throw e;
  console.log(`${label}: rejected ${e.name}`);
};

// Read the body chunk by chunk, logging each as it arrives.
const chunks = (reader, decoder) =>
  reader.read().then(({ done, value }) => {
    if (done) return void console.log("stream done");
    console.log(`stream chunk: ${JSON.stringify(decoder.decode(value, { stream: true }))}`);
    return chunks(reader, decoder);
  });

let controller = null;

const scenarios = {
  get: () => fetch("/api/items?x=1", { headers: [["X-B", "2"], ["x-a", "1"], ["X-B", "3"]] }).then(withText("get")),
  post: () => fetch("/api/save", { method: "POST", body: "hello", credentials: "include" }).then(withText("post")),
  form: () => {
    const form = new globalThis.FormData();
    form.append("name", "beni");
    form.append("n", "1");
    return fetch("/api/form", { method: "POST", body: form }).then(withText("form"));
  },
  stream: () => fetch("/big").then((r) => chunks(r.body.getReader(), new TextDecoder())),
  slow: () => {
    controller = new AbortController();
    return fetch("/slow", { signal: controller.signal }).then(
      () => console.log("slow: answered"),
      expecting("slow", (e) => e === controller.signal.reason),
    );
  },
  cancel: () => controller.abort(),
  down: () => fetch("/down").then(() => console.log("down: answered"), expecting("down", (e) => e instanceof TypeError)),
  data: () => fetch("data:text/plain,inline").then((r) => r.text().then((text) => console.log(`data: ${text}`))),
};

export const go = (name) => {
  scenarios[name]();
  return null;
};
