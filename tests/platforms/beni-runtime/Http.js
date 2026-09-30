// The sibling JavaScript of `Http.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name. `start` begins one
// `fetch`, resumes the waiting fiber once with a `Result`, and returns what
// aborts it (transparent-effects-proposal.md §16.5). Every failure is a
// constructor of `Http.Error`: nothing thrown reaches beni (§4.1).

const err = (e) => ({ $: "Err", a: e });

export const start = (method, url, contentType, body, json, resume) => {
  const abort = new globalThis.AbortController();
  const headers = {};
  if (contentType !== "") headers["Content-Type"] = contentType;
  if (json) headers.Accept = "application/json";
  try {
    new globalThis.URL(url, globalThis.location.href);
  } catch (e) {
    resume(err({ $: "BadUrl", a: url }));
    return (unit) => unit;
  }
  let pending;
  try {
    pending = globalThis.fetch(url, {
      method,
      headers,
      body: method === "GET" ? undefined : body,
      signal: abort.signal,
    });
  } catch (e) {
    resume(err({ $: "BadUrl", a: url }));
    return (unit) => unit;
  }
  pending
    .then((response) =>
      response.text().then((text) => {
        if (!response.ok) return err({ $: "BadStatus", a: response.status });
        if (json) {
          try {
            JSON.parse(text);
          } catch (e) {
            return err({ $: "BadBody", a: "not JSON" });
          }
        }
        return { $: "Ok", a: text };
      }),
    )
    .then(resume, () => resume(err({ $: "NetworkError", a: null })));
  return (unit) => {
    abort.abort();
    return unit;
  };
};
