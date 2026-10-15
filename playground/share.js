// The playground's shareable link (docs/design/playground.md §4.5, §4.6):
// the platform, the source and the CSS pane's text in the URL fragment,
// which never goes to the server. The source and the CSS are each
// compressed with the browser's `CompressionStream("deflate-raw")` and
// encoded in base64url; `css` is there only when the pane holds text:
//
//   #platform=browser-direct&code=<base64url>&css=<base64url>

/// The longest source, and the longest CSS, a link opens: a link is typed
/// by no one, and a few bytes of deflate data can stand for hundreds of
/// megabytes.
export const maxSource = 1024 * 1024;

/// The fragment, without its `#`, for `platform`, `source` and `css`. An
/// empty `css` adds nothing, so the link is the one made before the pane.
export async function encode(platform, source, css = "") {
  const params = new URLSearchParams({ platform, code: await pack(source) });
  if (css !== "") params.set("css", await pack(css));
  return params.toString();
}

/// `{ platform, source, css }` from a fragment `encode` made (with or
/// without its `#`); `css` is empty when the fragment has none. Null when
/// the fragment holds no source, and null when its source or its CSS is not
/// base64url, not deflate data, not UTF-8, or longer than `maxSource`: a
/// link cut short, edited by hand, or made to be large.
export async function decode(fragment) {
  const params = new URLSearchParams(fragment.replace(/^#/, ""));
  const code = params.get("code");
  if (code === null) return null;
  const source = await unpack(code);
  if (source === null) return null;
  const css = params.has("css") ? await unpack(params.get("css")) : "";
  if (css === null) return null;
  return { platform: params.get("platform"), source, css };
}

/// `text`, compressed and encoded in base64url.
async function pack(text) {
  const bytes = await compress(new TextEncoder().encode(text));
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/// The text `pack` made, or null when `packed` is not base64url, not
/// deflate data, not UTF-8, or longer than `maxSource`.
async function unpack(packed) {
  let binary;
  try {
    binary = atob(packed.replaceAll("-", "+").replaceAll("_", "/"));
  } catch (e) {
    // A character outside base64.
    if (e instanceof DOMException && e.name === "InvalidCharacterError") return null;
    throw e;
  }
  const bytes = await decompress(Uint8Array.from(binary, (c) => c.charCodeAt(0)));
  if (bytes === null) return null;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (e) {
    // A fatal decoder's answer to bytes that are not UTF-8.
    if (e instanceof TypeError) return null;
    throw e;
  }
}

async function compress(bytes) {
  const stream = new CompressionStream("deflate-raw");
  const writer = stream.writable.getWriter();
  const [out] = await Promise.all([new Response(stream.readable).arrayBuffer(), writer.write(bytes), writer.close()]);
  return new Uint8Array(out);
}

/// The inflated `bytes`, or null when they are not deflate data or inflate
/// past `maxSource`. The write, the close and the reads are awaited
/// together, so no rejection goes unhandled.
async function decompress(bytes) {
  const stream = new DecompressionStream("deflate-raw");
  const writer = stream.writable.getWriter();
  const reader = stream.readable.getReader();
  // What the reader is cancelled with past `maxSource`: the writer's side
  // then fails with this same object, and with nothing else.
  const tooLong = new Error("the source is longer than a link may hold");
  const written = Promise.all([writer.write(bytes), writer.close()]).then(
    () => true,
    (e) => {
      if (e === tooLong) return true;
      // The stream's answer to bytes that are not deflate data.
      if (e instanceof TypeError) return false;
      throw e;
    },
  );
  const chunks = [];
  let length = 0;
  for (;;) {
    const step = await reader.read().then(
      (r) => r,
      (e) => {
        if (e instanceof TypeError) return null;
        throw e;
      },
    );
    if (step === null) {
      await written;
      return null;
    }
    if (step.done) break;
    length += step.value.length;
    if (length > maxSource) {
      await reader.cancel(tooLong);
      await written;
      return null;
    }
    chunks.push(step.value);
  }
  if (!(await written)) return null;
  const out = new Uint8Array(length);
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return out;
}
