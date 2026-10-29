// The oracle for `tests/corpus/run/UrlWhatwg/` (docs/design/boundary.md
// §9.8.13 (a), its amendment of 2026-10-29): the expected output of each
// input in the fixture's `cases` list is the host's WHATWG `URL` read into
// Elm's record, exactly as `core/Url.beni`'s `fromString` read it before it
// became a parser of its own.
//
//   node tests/oracle/url-whatwg.mjs > tests/corpus/run/UrlWhatwg/_expected.expected
//
// The inputs are WPT's (url/resources/urltestdata.json and toascii.json at
// web-platform-tests/wpt c48d58747e1f, 2026-09-19); the answers are the Node
// that runs it (v24.19.0 recorded them). One departure is the rule's, not the
// host's: a host that is not ASCII once percent-decoded is `Nothing`, where
// the host maps it by UTS #46 to its `xn--` form. The script asserts that the
// host does accept each such input, so a case that stops being a departure is
// noticed.
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../corpus/run/UrlWhatwg/Main.beni", import.meta.url), "utf8");
const list = source.slice(source.indexOf("cases =")).split("\n    ]")[0];
const literal = /"((?:[^"\\]|\\.)*)"/g;
const unescape = (s) =>
  s.replace(/\\(u\{([0-9A-Fa-f]+)\}|.)/g, (_, e, hex) =>
    hex ? String.fromCodePoint(parseInt(hex, 16)) : { n: "\n", r: "\r", t: "\t" }[e] ?? e,
  );
const cases = [...list.matchAll(literal)].map((m) => unescape(m[1]));

// The text between the scheme's slashes and the path, after its last `@`.
const hostOf = (input) => {
  const authority = /^[^:]*:[\/\\]*([^\/\\?#]*)/.exec(input.replace(/[\t\n\r]/g, "").trim())[1];
  return authority.slice(authority.lastIndexOf("@") + 1);
};
const unicodeHost = (input) => {
  const bytes = hostOf(input).replace(/%([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
  return /[^\x00-\x7f]/.test(bytes);
};

const describe = (input) => {
  const url = URL.parse(input);
  if (url === null || url.username !== "" || url.password !== "") return "Nothing";
  const protocol = { "http:": "http", "https:": "https" }[url.protocol];
  if (protocol === undefined) return "Nothing";
  if (unicodeHost(input)) return "Nothing";
  const { href, hash, search } = url;
  const bareHash = hash === "" && href.endsWith("#");
  const beforeHash = href.slice(0, href.length - (bareHash ? 1 : hash.length));
  const query = search !== "" ? `[${search.slice(1)}]` : beforeHash.endsWith("?") ? "[]" : "-";
  const fragment = hash !== "" ? `[${hash.slice(1)}]` : bareHash ? "[]" : "-";
  const port = url.port === "" ? "-" : url.port;
  return `${protocol} ${url.hostname} ${port} ${url.pathname} ${query} ${fragment} = ${href}`;
};

for (const input of cases) {
  if (unicodeHost(input) && URL.parse(input) === null) throw new Error(`the host refuses ${JSON.stringify(input)} too`);
}
cases.forEach((input, i) => console.log(`${i + 1}: ${describe(input)}`));
