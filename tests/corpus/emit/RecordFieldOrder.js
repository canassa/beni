import { Basics$add } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const RecordFieldOrder$bump = (n$1) => Basics$add(n$1, 1);
const RecordFieldOrder$sortedFields = (a$1, b$2) => ({ alpha: RecordFieldOrder$bump(a$1), zed: RecordFieldOrder$bump(b$2) });
const RecordFieldOrder$unsortedFields = (a$1, b$2) => {
  const $t$1 = RecordFieldOrder$bump(a$1);
  const $t$2 = RecordFieldOrder$bump(b$2);
  return { alpha: $t$2, zed: $t$1 };
};
const RecordFieldOrder$unsortedAtoms = (a$1, b$2) => ({ alpha: b$2, zed: a$1 });
const RecordFieldOrder$unsortedOne = (a$1, b$2) => ({ alpha: b$2, zed: RecordFieldOrder$bump(a$1) });
const RecordFieldOrder$main = Node$printLines({ $: 0, a: null, b: null });
export { RecordFieldOrder$main, RecordFieldOrder$sortedFields, RecordFieldOrder$unsortedFields, RecordFieldOrder$unsortedAtoms, RecordFieldOrder$unsortedOne };
