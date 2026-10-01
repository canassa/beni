// The sibling JavaScript of `Http.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name. `start` begins one
// `fetch`, resumes the waiting fiber once with a `Result`, and returns what
// aborts it (transparent-effects-proposal.md §16.5).
//
// Each failure the Fetch and URL standards document is one constructor of
// `Http.Error`, caught by its kind and nothing broader (CLAUDE.md rule 9):
// `new URL` throws a `TypeError` for a URL it cannot parse (`BadUrl`);
// `fetch` and reading the body reject with a `TypeError` when no answer
// came (`NetworkError`) and with an `AbortError` after this file's own abort,
// when the fiber is gone and nothing waits; `JSON.parse` throws a
// `SyntaxError` (`BadBody`). Anything else is a defect: the fiber is resumed
// with it wrapped, `{ d: error }`, and `Http.beni` throws it there, so the
// page stops with the request's stack (boundary.md §9.8.10 (c)).

const err = (e) => ({ $: "Err", a: e });

export const start = (method, url, contentType, body, json, resume) => {
  const abort = new globalThis.AbortController();
  const headers = {};
  if (contentType !== "") headers["Content-Type"] = contentType;
  if (json) headers.Accept = "application/json";
  try {
    new globalThis.URL(url, globalThis.location.href);
  } catch (e) {
    if (!(e instanceof TypeError)) throw e;
    resume(err({ $: "BadUrl", a: url }));
    return (unit) => unit;
  }
  const failed = (e) => {
    if (e instanceof Error && e.name === "AbortError" && abort.signal.aborted) return;
    resume(e instanceof TypeError ? err({ $: "NetworkError", a: null }) : { d: e });
  };
  globalThis
    .fetch(url, {
      method,
      headers,
      body: method === "GET" ? undefined : body,
      signal: abort.signal,
    })
    .then(
      (response) =>
        response.text().then((text) => {
          if (!response.ok) return resume(err({ $: "BadStatus", a: response.status }));
          if (json) {
            try {
              JSON.parse(text);
            } catch (e) {
              if (!(e instanceof SyntaxError)) return resume({ d: e });
              return resume(err({ $: "BadBody", a: "not JSON" }));
            }
          }
          return resume({ $: "Ok", a: text });
        }, failed),
      failed,
    );
  return (unit) => {
    abort.abort();
    return unit;
  };
};
