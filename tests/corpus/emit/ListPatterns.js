import { List$unsafeGet, List$view, List$length, List$cons } from "./_core/List.mjs";
import { Basics$append } from "./_core/Basics.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const ListPatterns$Maybe$Nothing = { $: "Nothing", a: null };
const ListPatterns$describe = (xs$1) => {
  if (xs$1.length === 0) {
    return "empty";
  } else {
    if (xs$1.length === 1) {
      const x$2 = List$unsafeGet(xs$1, 0);
      return Basics$append("one ", String$fromInt(x$2));
    } else {
      const x$3 = List$unsafeGet(xs$1, 0);
      const y$4 = List$unsafeGet(xs$1, 1);
      const rest$5 = List$view(xs$1, 2);
      return Basics$append(String$fromInt(x$3), Basics$append(", ", Basics$append(String$fromInt(y$4), Basics$append(" and ", Basics$append(String$fromInt(List$length(rest$5)), " more")))));
    }
  }
};
const ListPatterns$exact = (xs$1) => {
  $j$0$2: {
    if (xs$1.length > 0) {
      if (xs$1.length > 1) {
        if (xs$1.length === 2) {
          const x$2 = List$unsafeGet(xs$1, 0);
          const y$3 = List$unsafeGet(xs$1, 1);
          return x$2 + y$3;
        } else {
          const x$4 = List$unsafeGet(xs$1, 0);
          const y$5 = List$unsafeGet(xs$1, 1);
          return x$4 - y$5;
        }
      } else {
        break $j$0$2;
      }
    } else {
      break $j$0$2;
    }
  }
  return 0;
};
const ListPatterns$nestedHead = (xss$1) => {
  $j$0$1: {
    if (xss$1.length > 0) {
      if (List$unsafeGet(xss$1, 0).length > 0) {
        const a$2 = List$unsafeGet(List$unsafeGet(xss$1, 0), 0);
        const inner$3 = List$view(List$unsafeGet(xss$1, 0), 1);
        const outer$4 = List$view(xss$1, 1);
        return a$2 + List$length(inner$3) + List$length(outer$4);
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return 0;
};
const ListPatterns$aliased = (xs$1) => {
  if (xs$1.length === 0) {
    return [];
  } else {
    const x$2 = List$unsafeGet(xs$1, 0);
    const whole$3 = xs$1;
    return List$cons(x$2, whole$3);
  }
};
const ListPatterns$firstOnly = (xs$1) => {
  if (xs$1.length === 0) {
    return 0;
  } else {
    const x$2 = List$unsafeGet(xs$1, 0);
    return x$2;
  }
};
const ListPatterns$second = (xs$1) => {
  $j$0$1: {
    if (xs$1.length > 0) {
      if (xs$1.length > 1) {
        const y$2 = List$unsafeGet(xs$1, 1);
        return { $: "Just", a: y$2 };
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return ListPatterns$Maybe$Nothing;
};
const ListPatterns$main = Node$printLines([]);
export { ListPatterns$main, ListPatterns$describe, ListPatterns$exact, ListPatterns$nestedHead, ListPatterns$aliased, ListPatterns$firstOnly, ListPatterns$second };
