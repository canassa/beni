import { List$unsafeGet, List$slice } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const ListSpreadPatterns$lastOr = (xs$1) => {
  if (xs$1.length === 0) {
    return 0;
  } else {
    const last$3 = List$unsafeGet(xs$1, xs$1.length - 1);
    return last$3;
  }
};
const ListSpreadPatterns$middle = (xs$1) => {
  $j$0$1: {
    if (xs$1.length === 0) {
      break $j$0$1;
    } else {
      if (xs$1.length === 1) {
        break $j$0$1;
      } else {
        const first$2 = List$unsafeGet(xs$1, 0);
        const between$3 = List$slice(xs$1, 1, xs$1.length - 1);
        const last$4 = List$unsafeGet(xs$1, xs$1.length - 1);
        return between$3;
      }
    }
  }
  return [];
};
const ListSpreadPatterns$endsInZero = (xs$1) => {
  $j$0$1: {
    if (xs$1.length === 0) {
      break $j$0$1;
    } else {
      if (List$unsafeGet(xs$1, xs$1.length - 1) === 0) {
        return true;
      } else {
        break $j$0$1;
      }
    }
  }
  return false;
};
const ListSpreadPatterns$headOr = (xs$1) => {
  if (xs$1.length === 0) {
    return 0;
  } else {
    const x$2 = List$unsafeGet(xs$1, 0);
    return x$2;
  }
};
const ListSpreadPatterns$main = Node$printLines([]);
export { ListSpreadPatterns$main, ListSpreadPatterns$lastOr, ListSpreadPatterns$middle, ListSpreadPatterns$endsInZero, ListSpreadPatterns$headOr };
//# sourceMappingURL=ListSpreadPatterns.mjs.map
