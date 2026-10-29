// Writes the tree of `Tree.beni` below the working directory, replacing a
// tree an earlier call left.
import fs from "node:fs";

export const makeTree = (unit) => {
  fs.rmSync("data", { recursive: true, force: true });
  fs.mkdirSync("data/sub", { recursive: true });
  fs.mkdirSync("data/empty");
  for (const name of ["b.txt", "a.txt", "Z.txt", "é.txt", "ｱ.txt", "\u{1f600}.txt", "sub/inner.txt", "empty/.keep"]) {
    fs.writeFileSync(`data/${name}`, "x\n");
  }
  fs.symlinkSync("a.txt", "data/link");
  fs.symlinkSync("missing", "data/dangling");
  fs.symlinkSync("loop", "data/loop");
  return unit;
};
