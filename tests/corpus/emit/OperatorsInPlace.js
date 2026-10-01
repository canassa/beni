import { Basics$idiv } from "./_core/Basics.mjs";
import { Int$mod, Int$rem } from "./_core/Int.mjs";
import { Int32$mul } from "./_core/Int32.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const OperatorsInPlace$arithmetic = (a$1, b$2) => a$1 + b$2 * 2 - (a$1 - b$2);
const OperatorsInPlace$floats = (x$1, y$2) => x$1 / y$2 + (0 - x$1);
const OperatorsInPlace$power = (a$1, b$2, c$3) => a$1 ** b$2 ** c$3;
const OperatorsInPlace$powerLeft = (a$1, b$2, c$3) => (a$1 ** b$2) ** c$3;
const OperatorsInPlace$powerOfNegation = (a$1, b$2) => (0 - a$1) ** b$2;
const OperatorsInPlace$byName = (a$1, b$2) => a$1 < b$2 && a$1 >= b$2;
const OperatorsInPlace$notBoth = (a$1, b$2) => !(a$1 && b$2) || !a$1;
const OperatorsInPlace$divide = (a$1, b$2) => Basics$idiv(a$1, b$2) + Int$mod(b$2, a$1) + Int$rem(b$2, a$1);
const OperatorsInPlace$wrap = (a$1, b$2) => (a$1 - b$2 | 0) + (1 | 0) | 0;
const OperatorsInPlace$bits = (a$1, b$2) => a$1 & b$2 ^ (a$1 << 3 | (b$2 >>> 2 | 0));
const OperatorsInPlace$product = (a$1, b$2) => Int32$mul(a$1 >> 1, b$2) >>> 0;
const OperatorsInPlace$main = Node$printLines([]);
export { OperatorsInPlace$main, OperatorsInPlace$arithmetic, OperatorsInPlace$floats, OperatorsInPlace$power, OperatorsInPlace$powerLeft, OperatorsInPlace$powerOfNegation, OperatorsInPlace$byName, OperatorsInPlace$notBoth, OperatorsInPlace$divide, OperatorsInPlace$wrap, OperatorsInPlace$bits, OperatorsInPlace$product };
//# sourceMappingURL=OperatorsInPlace.mjs.map
