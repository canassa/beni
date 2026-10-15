// The playground's shareable link (docs/design/playground.md §4.5): the
// platform and the source in the URL fragment, which never goes to the
// server. The source is compressed with the browser's
// `CompressionStream("deflate-raw")` and encoded in base64url:
//
//   #platform=browser-direct&code=<base64url>

/// The fragment, without its `#`, for `platform` and `source`.
export async function encode(platform, source) {
  const bytes = await transform(new TextEncoder().encode(source), new CompressionStream("deflate-raw"));
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  }
  const code = btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  return new URLSearchParams({ platform, code }).toString();
}

/// `{ platform, source }` from a fragment `encode` made (with or without
/// its `#`); null when the fragment holds no source, and null when its
/// source is not base64url or not deflate data: a link cut short, or edited
/// by hand.
export async function decode(fragment) {
  const params = new URLSearchParams(fragment.replace(/^#/, ""));
  const code = params.get("code");
  if (code === null) return null;
  try {
    const binary = atob(code.replaceAll("-", "+").replaceAll("_", "/"));
    const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    const source = new TextDecoder("utf-8", { fatal: true }).decode(await transform(bytes, new DecompressionStream("deflate-raw")));
    return { platform: params.get("platform"), source };
  } catch (e) {
    // `atob` names a character outside base64; a decompression stream and
    // a fatal decoder reject damaged data with a `TypeError`. Anything else
    // is not a damaged link.
    if ((e instanceof DOMException && e.name === "InvalidCharacterError") || e instanceof TypeError) return null;
    throw e;
  }
}

/// `bytes` through `stream`. The write, the close and the read are awaited
/// together, so a stream that rejects damaged data leaves no rejection
/// unhandled.
async function transform(bytes, stream) {
  const writer = stream.writable.getWriter();
  const [out] = await Promise.all([new Response(stream.readable).arrayBuffer(), writer.write(bytes), writer.close()]);
  return new Uint8Array(out);
}
