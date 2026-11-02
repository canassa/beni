export const url = (response) => { return response.url; };
export const status = (response) => { return response.status; };
export const statusText = (response) => { return response.statusText; };
export const ok = (response) => { return response.ok; };
export const headers = (response) => { return response.headers; };
export const text = (response) => { return response.text(); };
export const reader = (response) => { const stream = response.body; return stream === null ? { $: "Nothing", a: null } : { $: "Just", a: stream.getReader() }; };
