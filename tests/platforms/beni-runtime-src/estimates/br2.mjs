// brotli of each runtime part, alone and followed by the empty page's
// program part (so the context the page compresses in is the same).
import z from "node:zlib";
import fs from "node:fs";
const br = (s) => z.brotliCompressSync(Buffer.from(s), { params: { [z.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const base = fs.readFileSync(process.argv[2], "utf8");
const program = base.slice(base.indexOf("\nlet "));
for (const f of process.argv.slice(3)) {
  const t = fs.readFileSync(f, "utf8");
  console.log(f.padEnd(16), "raw", String(t.length).padStart(5), "br", String(br(t)).padStart(5), "page raw", String(t.length + program.length).padStart(5), "page br", String(br(t + program)).padStart(5));
}
